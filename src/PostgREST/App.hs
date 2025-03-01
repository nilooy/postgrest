{-|
Module      : PostgREST.App
Description : PostgREST main application

This module is in charge of mapping HTTP requests to PostgreSQL queries.
Some of its functionality includes:

- Mapping HTTP request methods to proper SQL statements. For example, a GET request is translated to executing a SELECT query in a read-only TRANSACTION.
- Producing HTTP Headers according to RFCs.
- Content Negotiation
-}
{-# LANGUAGE RecordWildCards #-}
module PostgREST.App
  ( SignalHandlerInstaller
  , SocketRunner
  , postgrest
  , run
  ) where

import Control.Monad.Except     (liftEither)
import Data.Either.Combinators  (mapLeft)
import Data.List                (union)
import Data.Maybe               (fromJust)
import Data.String              (IsString (..))
import Network.Wai.Handler.Warp (defaultSettings, setHost, setPort,
                                 setServerName)
import System.Posix.Types       (FileMode)

import qualified Data.ByteString.Char8           as BS
import qualified Data.ByteString.Lazy            as LBS
import qualified Data.HashMap.Strict             as HM
import qualified Data.Set                        as S
import qualified Hasql.DynamicStatements.Snippet as SQL (Snippet)
import qualified Hasql.Transaction               as SQL
import qualified Hasql.Transaction.Sessions      as SQL
import qualified Network.HTTP.Types.Header       as HTTP
import qualified Network.HTTP.Types.Status       as HTTP
import qualified Network.HTTP.Types.URI          as HTTP
import qualified Network.Wai                     as Wai
import qualified Network.Wai.Handler.Warp        as Warp

import qualified PostgREST.Admin                    as Admin
import qualified PostgREST.AppState                 as AppState
import qualified PostgREST.Auth                     as Auth
import qualified PostgREST.Cors                     as Cors
import qualified PostgREST.DbStructure              as DbStructure
import qualified PostgREST.Error                    as Error
import qualified PostgREST.Logger                   as Logger
import qualified PostgREST.Middleware               as Middleware
import qualified PostgREST.OpenAPI                  as OpenAPI
import qualified PostgREST.Query.QueryBuilder       as QueryBuilder
import qualified PostgREST.Query.Statements         as Statements
import qualified PostgREST.RangeQuery               as RangeQuery
import qualified PostgREST.Request.ApiRequest       as ApiRequest
import qualified PostgREST.Request.DbRequestBuilder as ReqBuilder
import qualified PostgREST.Request.Types            as ApiRequestTypes

import PostgREST.AppState                (AppState)
import PostgREST.Auth                    (AuthResult (..))
import PostgREST.Config                  (AppConfig (..),
                                          LogLevel (..),
                                          OpenAPIMode (..))
import PostgREST.Config.PgVersion        (PgVersion (..))
import PostgREST.DbStructure             (DbStructure (..))
import PostgREST.DbStructure.Identifiers (FieldName,
                                          QualifiedIdentifier (..),
                                          Schema)
import PostgREST.DbStructure.Proc        (ProcDescription (..),
                                          ProcVolatility (..))
import PostgREST.DbStructure.Table       (Table (..))
import PostgREST.Error                   (Error)
import PostgREST.GucHeader               (GucHeader,
                                          addHeadersIfNotIncluded,
                                          unwrapGucHeader)
import PostgREST.MediaType               (MTPlanAttrs (..),
                                          MediaType (..))
import PostgREST.Query.Statements        (ResultSet (..))
import PostgREST.Request.ApiRequest      (Action (..),
                                          ApiRequest (..),
                                          InvokeMethod (..),
                                          Mutation (..), Target (..))
import PostgREST.Request.Preferences     (PreferCount (..),
                                          PreferParameters (..),
                                          PreferRepresentation (..),
                                          toAppliedHeader)
import PostgREST.Request.QueryParams     (QueryParams (..))
import PostgREST.Request.ReadQuery       (ReadRequest, fstFieldNames)
import PostgREST.Version                 (prettyVersion)
import PostgREST.Workers                 (connectionWorker, listener)

import qualified PostgREST.DbStructure.Proc as Proc
import qualified PostgREST.MediaType        as MediaType

import Protolude hiding (Handler)

data RequestContext = RequestContext
  { ctxConfig      :: AppConfig
  , ctxDbStructure :: DbStructure
  , ctxApiRequest  :: ApiRequest
  , ctxPgVersion   :: PgVersion
  }

type Handler = ExceptT Error

type DbHandler = Handler SQL.Transaction

type SignalHandlerInstaller = AppState -> IO()

type SocketRunner = Warp.Settings -> Wai.Application -> FileMode -> FilePath -> IO()


run :: SignalHandlerInstaller -> Maybe SocketRunner -> AppState -> IO ()
run installHandlers maybeRunWithSocket appState = do
  conf@AppConfig{..} <- AppState.getConfig appState
  connectionWorker appState -- Loads the initial DbStructure
  installHandlers appState
  -- reload schema cache + config on NOTIFY
  when configDbChannelEnabled $ listener appState

  let app = postgrest configLogLevel appState (connectionWorker appState)
      adminApp = Admin.postgrestAdmin appState conf

  whenJust configAdminServerPort $ \adminPort -> do
    AppState.logWithZTime appState $ "Admin server listening on port " <> show adminPort
    void . forkIO $ Warp.runSettings (serverSettings conf & setPort adminPort) adminApp

  case configServerUnixSocket of
    Just socket ->
      -- run the postgrest application with user defined socket. Only for UNIX systems
      case maybeRunWithSocket of
        Just runWithSocket -> do
          AppState.logWithZTime appState $ "Listening on unix socket " <> show socket
          runWithSocket (serverSettings conf) app configServerUnixSocketMode socket
        Nothing ->
          panic "Cannot run with unix socket on non-unix platforms."
    Nothing ->
      do
        AppState.logWithZTime appState $ "Listening on port " <> show configServerPort
        Warp.runSettings (serverSettings conf) app
  where
    whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
    whenJust mg f = maybe (pure ()) f mg

serverSettings :: AppConfig -> Warp.Settings
serverSettings AppConfig{..} =
  defaultSettings
    & setHost (fromString $ toS configServerHost)
    & setPort configServerPort
    & setServerName ("postgrest/" <> prettyVersion)

-- | PostgREST application
postgrest :: LogLevel -> AppState.AppState -> IO () -> Wai.Application
postgrest logLevel appState connWorker =
  Cors.middleware .
  Auth.middleware appState .
  Logger.middleware logLevel $
    -- fromJust can be used, because the auth middleware will **always** add
    -- some AuthResult to the vault.
    \req respond -> case fromJust $ Auth.getResult req of
      Left err -> respond $ Error.errorResponseFor err
      Right authResult -> do
        conf <- AppState.getConfig appState
        maybeDbStructure <- AppState.getDbStructure appState
        pgVer <- AppState.getPgVersion appState
        jsonDbS <- AppState.getJsonDbS appState

        let
          eitherResponse :: IO (Either Error Wai.Response)
          eitherResponse =
            runExceptT $ postgrestResponse appState conf maybeDbStructure jsonDbS pgVer authResult req

        response <- either Error.errorResponseFor identity <$> eitherResponse
        -- Launch the connWorker when the connection is down.  The postgrest
        -- function can respond successfully (with a stale schema cache) before
        -- the connWorker is done.
        let isPGAway = Wai.responseStatus response == HTTP.status503
        when isPGAway connWorker
        resp <- addRetryHint isPGAway appState response
        respond resp

addRetryHint :: Bool -> AppState -> Wai.Response -> IO Wai.Response
addRetryHint shouldAdd appState response = do
  delay <- AppState.getRetryNextIn appState
  let h = ("Retry-After", BS.pack $ show delay)
  return $ Wai.mapResponseHeaders (\hs -> if shouldAdd then h:hs else hs) response

postgrestResponse
  :: AppState.AppState
  -> AppConfig
  -> Maybe DbStructure
  -> ByteString
  -> PgVersion
  -> AuthResult
  -> Wai.Request
  -> Handler IO Wai.Response
postgrestResponse appState conf@AppConfig{..} maybeDbStructure jsonDbS pgVer AuthResult{..} req = do
  body <- lift $ Wai.strictRequestBody req

  dbStructure <-
    case maybeDbStructure of
      Just dbStructure ->
        return dbStructure
      Nothing ->
        throwError Error.NoSchemaCacheError

  apiRequest <-
    liftEither . mapLeft Error.ApiRequestError $
      ApiRequest.userApiRequest conf dbStructure req body

  let ctx apiReq = RequestContext conf dbStructure apiReq pgVer

  if iAction apiRequest == ActionInfo then
    handleInfo (iTarget apiRequest) (ctx apiRequest)
  else
    runDbHandler appState (txMode apiRequest) (Just authRole /= configDbAnonRole) configDbPreparedStatements .
      Middleware.optionalRollback conf apiRequest $
        Middleware.runPgLocals conf authClaims authRole (handleRequest . ctx) apiRequest jsonDbS pgVer

runDbHandler :: AppState.AppState -> SQL.Mode -> Bool -> Bool -> DbHandler b -> Handler IO b
runDbHandler appState mode authenticated prepared handler = do
  dbResp <-
    let transaction = if prepared then SQL.transaction else SQL.unpreparedTransaction in
    lift . AppState.usePool appState . transaction SQL.ReadCommitted mode $ runExceptT handler

  resp <-
    liftEither . mapLeft Error.PgErr $
      mapLeft (Error.PgError authenticated) dbResp

  liftEither resp

handleRequest :: RequestContext -> DbHandler Wai.Response
handleRequest context@(RequestContext _ _ ApiRequest{..} _) =
  case (iAction, iTarget) of
    (ActionRead headersOnly, TargetIdent identifier) ->
      handleRead headersOnly identifier context
    (ActionMutate MutationCreate, TargetIdent identifier) ->
      handleCreate identifier context
    (ActionMutate MutationUpdate, TargetIdent identifier) ->
      handleUpdate identifier context
    (ActionMutate MutationSingleUpsert, TargetIdent identifier) ->
      handleSingleUpsert identifier context
    (ActionMutate MutationDelete, TargetIdent identifier) ->
      handleDelete identifier context
    (ActionInvoke invMethod, TargetProc proc _) ->
      handleInvoke invMethod proc context
    (ActionInspect headersOnly, TargetDefaultSpec tSchema) ->
      handleOpenApi headersOnly tSchema context
    _ ->
      -- This is unreachable as the ApiRequest.hs rejects it before
      -- TODO Refactor the Action/Target types to remove this line
      throwError $ Error.ApiRequestError ApiRequestTypes.NotFound

handleRead :: Bool -> QualifiedIdentifier -> RequestContext -> DbHandler Wai.Response
handleRead headersOnly identifier context@RequestContext{..} = do
  req <- readRequest identifier context
  bField <- binaryField context req

  let
    ApiRequest{..} = ctxApiRequest
    AppConfig{..} = ctxConfig
    countQuery = QueryBuilder.readRequestToCountQuery req

  resultSet <-
     lift . SQL.statement mempty $
      Statements.prepareRead
        (QueryBuilder.readRequestToQuery req)
        (if iPreferCount == Just EstimatedCount then
           -- LIMIT maxRows + 1 so we can determine below that maxRows was surpassed
           QueryBuilder.limitedQuery countQuery ((+ 1) <$> configDbMaxRows)
         else
           countQuery
        )
        (shouldCount iPreferCount)
        iAcceptMediaType
        bField
        configDbPreparedStatements

  case resultSet of
    RSStandard{..} -> do
      total <- readTotal ctxConfig ctxApiRequest rsTableTotal countQuery
      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders

      let
        (status, contentRange) = RangeQuery.rangeStatusHeader iTopLevelRange rsQueryTotal total
        headers =
          [ contentRange
          , ( "Content-Location"
            , "/"
                <> toUtf8 (qiName identifier)
                <> if BS.null (qsCanonical iQueryParams) then mempty else "?" <> qsCanonical iQueryParams
            )
          ]
          ++ contentTypeHeaders context

      failNotSingular iAcceptMediaType rsQueryTotal . response status headers $
        if headersOnly then mempty else LBS.fromStrict rsBody

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

readTotal :: AppConfig -> ApiRequest -> Maybe Int64 -> SQL.Snippet -> DbHandler (Maybe Int64)
readTotal AppConfig{..} ApiRequest{..} tableTotal countQuery =
  case iPreferCount of
    Just PlannedCount ->
      explain
    Just EstimatedCount ->
      if tableTotal > (fromIntegral <$> configDbMaxRows) then
        max tableTotal <$> explain
      else
        return tableTotal
    _ ->
      return tableTotal
  where
    explain =
      lift . SQL.statement mempty . Statements.preparePlanRows countQuery $
        configDbPreparedStatements

handleCreate :: QualifiedIdentifier -> RequestContext -> DbHandler Wai.Response
handleCreate identifier@QualifiedIdentifier{..} context@RequestContext{..} = do
  let
    ApiRequest{..} = ctxApiRequest
    pkCols = if iPreferRepresentation /= None || isJust iPreferResolution
      then maybe mempty tablePKCols $ HM.lookup identifier $ dbTables ctxDbStructure
      else mempty

  resultSet <- writeQuery MutationCreate identifier True pkCols context

  case resultSet of
    RSStandard{..} -> do

      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders

      let
        headers =
          catMaybes
            [ if null rsLocation then
                Nothing
              else
                Just
                  ( HTTP.hLocation
                  , "/"
                      <> toUtf8 qiName
                      <> HTTP.renderSimpleQuery True rsLocation
                  )
            , Just . RangeQuery.contentRangeH 1 0 $
                if shouldCount iPreferCount then Just rsQueryTotal else Nothing
            , if null pkCols && isNothing (qsOnConflict iQueryParams) then
                Nothing
              else
                toAppliedHeader <$> iPreferResolution
            ]

      failNotSingular iAcceptMediaType rsQueryTotal $
        if iPreferRepresentation == Full then
          response HTTP.status201 (headers ++ contentTypeHeaders context) (LBS.fromStrict rsBody)
        else
          response HTTP.status201 headers mempty

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

handleUpdate :: QualifiedIdentifier -> RequestContext -> DbHandler Wai.Response
handleUpdate identifier context@RequestContext{..} = do
  let
    ApiRequest{..} = ctxApiRequest
    pkCols = maybe mempty tablePKCols $ HM.lookup identifier $ dbTables ctxDbStructure

  resultSet <- writeQuery MutationUpdate identifier False pkCols context

  case resultSet of
    RSStandard{..} -> do
      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders

      let
        fullRepr = iPreferRepresentation == Full
        updateIsNoOp = S.null iColumns
        status
          | rsQueryTotal == 0 && not updateIsNoOp = HTTP.status404
          | fullRepr = HTTP.status200
          | otherwise = HTTP.status204
        contentRangeHeader =
          RangeQuery.contentRangeH 0 (rsQueryTotal - 1) $
            if shouldCount iPreferCount then Just rsQueryTotal else Nothing

      failChangesOffLimits (RangeQuery.rangeLimit iTopLevelRange) rsQueryTotal =<<
        failNotSingular iAcceptMediaType rsQueryTotal (
          if fullRepr then
            response status (contentTypeHeaders context ++ [contentRangeHeader]) (LBS.fromStrict rsBody)
          else
            response status [contentRangeHeader] mempty)

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

handleSingleUpsert :: QualifiedIdentifier -> RequestContext-> DbHandler Wai.Response
handleSingleUpsert identifier context@(RequestContext _ ctxDbStructure ApiRequest{..} _) = do
  let pkCols = maybe mempty tablePKCols $ HM.lookup identifier $ dbTables ctxDbStructure

  resultSet <- writeQuery MutationSingleUpsert identifier False pkCols context

  case resultSet of
    RSStandard {..} -> do

      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders

      -- Makes sure the querystring pk matches the payload pk
      -- e.g. PUT /items?id=eq.1 { "id" : 1, .. } is accepted,
      -- PUT /items?id=eq.14 { "id" : 2, .. } is rejected.
      -- If this condition is not satisfied then nothing is inserted,
      -- check the WHERE for INSERT in QueryBuilder.hs to see how it's done
      when (rsQueryTotal /= 1) $ do
        lift SQL.condemn
        throwError Error.PutMatchingPkError

      return $
        if iPreferRepresentation == Full then
          response HTTP.status200 (contentTypeHeaders context) (LBS.fromStrict rsBody)
        else
          response HTTP.status204 [] mempty

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

handleDelete :: QualifiedIdentifier -> RequestContext -> DbHandler Wai.Response
handleDelete identifier context@(RequestContext _ _ ApiRequest{..} _) = do
  resultSet <- writeQuery MutationDelete identifier False mempty context

  case resultSet of
    RSStandard {..} -> do

      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders

      let
        contentRangeHeader =
          RangeQuery.contentRangeH 1 0 $
            if shouldCount iPreferCount then Just rsQueryTotal else Nothing

      failChangesOffLimits (RangeQuery.rangeLimit iTopLevelRange) rsQueryTotal =<<
        failNotSingular iAcceptMediaType rsQueryTotal (
          if iPreferRepresentation == Full then
            response HTTP.status200
              (contentTypeHeaders context ++ [contentRangeHeader])
              (LBS.fromStrict rsBody)
          else
            response HTTP.status204 [contentRangeHeader] mempty)

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

handleInfo :: Monad m => Target -> RequestContext -> Handler m Wai.Response
handleInfo target RequestContext{..} =
  case target of
    TargetIdent identifier ->
      case HM.lookup identifier (dbTables ctxDbStructure) of
        Just tbl -> infoResponse $ allowH tbl
        Nothing  -> throwError $ Error.ApiRequestError ApiRequestTypes.NotFound
    TargetProc pd _
      | pdVolatility pd == Volatile -> infoResponse "OPTIONS,POST"
      | otherwise                   -> infoResponse "OPTIONS,GET,HEAD,POST"
    TargetDefaultSpec _             -> infoResponse "OPTIONS,GET,HEAD"
  where
    infoResponse allowHeader = return $ Wai.responseLBS HTTP.status200 [allOrigins, (HTTP.hAllow, allowHeader)] mempty
    allOrigins = ("Access-Control-Allow-Origin", "*")
    allowH table =
      let hasPK = not . null $ tablePKCols table in
      BS.intercalate "," $
          ["OPTIONS,GET,HEAD"] ++
          ["POST" | tableInsertable table] ++
          ["PUT" | tableInsertable table && tableUpdatable table && hasPK] ++
          ["PATCH" | tableUpdatable table] ++
          ["DELETE" | tableDeletable table]

handleInvoke :: InvokeMethod -> ProcDescription -> RequestContext -> DbHandler Wai.Response
handleInvoke invMethod proc context@RequestContext{..} = do
  let
    ApiRequest{..} = ctxApiRequest

    identifier =
      QualifiedIdentifier
        (pdSchema proc)
        (fromMaybe (pdName proc) $ Proc.procTableName proc)

  req <- readRequest identifier context
  bField <- binaryField context req

  let callReq = ReqBuilder.callRequest proc ctxApiRequest req

  resultSet <-
    lift . SQL.statement mempty $
      Statements.prepareCall
        (Proc.procReturnsScalar proc)
        (Proc.procReturnsSingle proc)
        (QueryBuilder.requestToCallProcQuery callReq)
        (QueryBuilder.readRequestToQuery req)
        (QueryBuilder.readRequestToCountQuery req)
        (shouldCount iPreferCount)
        iAcceptMediaType
        (iPreferParameters == Just MultipleObjects)
        bField
        (configDbPreparedStatements ctxConfig)

  case resultSet of
    RSStandard {..} -> do
      response <- liftEither $ gucResponse <$> rsGucStatus <*> rsGucHeaders
      let
        (status, contentRange) =
          RangeQuery.rangeStatusHeader iTopLevelRange rsQueryTotal rsTableTotal

      failNotSingular iAcceptMediaType rsQueryTotal $
        if Proc.procReturnsVoid proc then
          response HTTP.status204 [contentRange] mempty
        else
          response status
            (contentTypeHeaders context ++ [contentRange])
            (if invMethod == InvHead then mempty else LBS.fromStrict rsBody)

    RSPlan plan ->
      pure $ Wai.responseLBS HTTP.status200 (contentTypeHeaders context) $ LBS.fromStrict plan

handleOpenApi :: Bool -> Schema -> RequestContext -> DbHandler Wai.Response
handleOpenApi headersOnly tSchema (RequestContext conf@AppConfig{..} dbStructure apiRequest ctxPgVersion) = do
  body <-
    lift $ case configOpenApiMode of
      OAFollowPriv ->
        OpenAPI.encode conf dbStructure
           <$> SQL.statement [tSchema] (DbStructure.accessibleTables ctxPgVersion configDbPreparedStatements)
           <*> SQL.statement tSchema (DbStructure.accessibleProcs ctxPgVersion configDbPreparedStatements)
           <*> SQL.statement tSchema (DbStructure.schemaDescription configDbPreparedStatements)
      OAIgnorePriv ->
        OpenAPI.encode conf dbStructure
              (HM.filterWithKey (\(QualifiedIdentifier sch _) _ ->  sch == tSchema) $ DbStructure.dbTables dbStructure)
              (HM.filterWithKey (\(QualifiedIdentifier sch _) _ ->  sch == tSchema) $ DbStructure.dbProcs dbStructure)
          <$> SQL.statement tSchema (DbStructure.schemaDescription configDbPreparedStatements)
      OADisabled ->
        pure mempty

  return $
    Wai.responseLBS HTTP.status200
      (MediaType.toContentType MTOpenAPI : maybeToList (profileHeader apiRequest))
      (if headersOnly then mempty else body)

txMode :: ApiRequest -> SQL.Mode
txMode ApiRequest{..} =
  case (iAction, iTarget) of
    (ActionRead _, _) ->
      SQL.Read
    (ActionInfo, _) ->
      SQL.Read
    (ActionInspect _, _) ->
      SQL.Read
    (ActionInvoke InvGet, _) ->
      SQL.Read
    (ActionInvoke InvHead, _) ->
      SQL.Read
    (ActionInvoke InvPost, TargetProc ProcDescription{pdVolatility=Stable} _) ->
      SQL.Read
    (ActionInvoke InvPost, TargetProc ProcDescription{pdVolatility=Immutable} _) ->
      SQL.Read
    _ ->
      SQL.Write

writeQuery :: Mutation -> QualifiedIdentifier -> Bool -> [Text] -> RequestContext -> DbHandler ResultSet
writeQuery mutation identifier@QualifiedIdentifier{..} isInsert pkCols context@RequestContext{..} = do
  readReq <- readRequest identifier context

  mutateReq <-
    liftEither $
      ReqBuilder.mutateRequest mutation qiSchema qiName ctxApiRequest
        pkCols
        readReq

  lift . SQL.statement mempty $
    Statements.prepareWrite
      (QueryBuilder.readRequestToQuery readReq)
      (QueryBuilder.mutateRequestToQuery mutateReq)
      isInsert
      (iAcceptMediaType ctxApiRequest)
      (iPreferRepresentation ctxApiRequest)
      pkCols
      (configDbPreparedStatements ctxConfig)

-- | Response with headers and status overridden from GUCs.
gucResponse
  :: Maybe HTTP.Status
  -> [GucHeader]
  -> HTTP.Status
  -> [HTTP.Header]
  -> LBS.ByteString
  -> Wai.Response
gucResponse gucStatus gucHeaders status headers =
  Wai.responseLBS (fromMaybe status gucStatus) $
    addHeadersIfNotIncluded headers (map unwrapGucHeader gucHeaders)

-- |
-- Fail a response if a single JSON object was requested and not exactly one
-- was found.
failNotSingular :: MediaType -> Int64 -> Wai.Response -> DbHandler Wai.Response
failNotSingular mediaType queryTotal response =
  if mediaType == MTSingularJSON && queryTotal /= 1 then
    do
      lift SQL.condemn
      throwError $ Error.singularityError queryTotal
  else
    return response

failChangesOffLimits :: Maybe Integer -> Int64 -> Wai.Response -> DbHandler Wai.Response
failChangesOffLimits (Just maxChanges) queryTotal response =
  if queryTotal > fromIntegral maxChanges
  then do
      lift SQL.condemn
      throwError $ Error.OffLimitsChangesError queryTotal maxChanges
  else
    return response
failChangesOffLimits _ _ response = return response

shouldCount :: Maybe PreferCount -> Bool
shouldCount preferCount =
  preferCount == Just ExactCount || preferCount == Just EstimatedCount

returnsScalar :: ApiRequest.Target -> Bool
returnsScalar (TargetProc proc _) = Proc.procReturnsScalar proc
returnsScalar _                   = False

readRequest :: Monad m => QualifiedIdentifier -> RequestContext -> Handler m ReadRequest
readRequest QualifiedIdentifier{..} (RequestContext AppConfig{..} dbStructure apiRequest _) =
  liftEither $
    ReqBuilder.readRequest qiSchema qiName configDbMaxRows
      (dbRelationships dbStructure)
      apiRequest

contentTypeHeaders :: RequestContext -> [HTTP.Header]
contentTypeHeaders RequestContext{..} =
  MediaType.toContentType (iAcceptMediaType ctxApiRequest) : maybeToList (profileHeader ctxApiRequest)

-- | If raw(binary) output is requested, check that MediaType is one of the
-- admitted rawMediaTypes and that`?select=...` contains only one field other
-- than `*`
binaryField :: Monad m => RequestContext -> ReadRequest -> Handler m (Maybe FieldName)
binaryField RequestContext{..} readReq
  | returnsScalar (iTarget ctxApiRequest) && isRawMediaType =
      return $ Just "pgrst_scalar"
  | isRawMediaType =
      let
        fldNames = fstFieldNames readReq
        fieldName = headMay fldNames
      in
      if length fldNames == 1 && fieldName /= Just "*" then
        return fieldName
      else
        throwError $ Error.BinaryFieldError mediaType
  | otherwise =
      return Nothing
  where
    mediaType = iAcceptMediaType ctxApiRequest
    isRawMediaType = mediaType `elem` configRawMediaTypes ctxConfig `union` [MTOctetStream, MTTextPlain, MTTextXML] || isRawPlan mediaType
    isRawPlan mt = case mt of
      MTPlan (MTPlanAttrs (Just MTOctetStream) _ _) -> True
      MTPlan (MTPlanAttrs (Just MTTextPlain) _ _)   -> True
      MTPlan (MTPlanAttrs (Just MTTextXML) _ _)     -> True
      _                                             -> False

profileHeader :: ApiRequest -> Maybe HTTP.Header
profileHeader ApiRequest{..} =
  (,) "Content-Profile" <$> (toUtf8 <$> iProfile)
