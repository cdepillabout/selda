{-# LANGUAGE OverloadedStrings, RecordWildCards, GADTs #-}
-- | PostgreSQL backend for Selda.
module Database.Selda.PostgreSQL
  ( PGConnectInfo (..), PGConnectException (..)
  , withPostgreSQL, on, auth
  ) where
import qualified Data.ByteString.Char8 as BS
import Data.Monoid
import qualified Data.Text as T
import Data.Text.Encoding
import Database.PostgreSQL.LibPQ hiding (user, pass, db, host)
import Database.Selda.Backend
import Control.Monad.Catch

-- | The exception thrown when a connection could not be made to the PostgreSQL
--   server.
data PGConnectException = PGConnectException String
  deriving Show
instance Exception PGConnectException

-- | PostgreSQL connection information.
data PGConnectInfo = PGConnectInfo
  { -- | Host to connect to.
    pgHost     :: T.Text
    -- | Port to connect to.
  , pgPort     :: Int
    -- | Name of database to use.
  , pgDatabase :: T.Text
    -- | Username for authentication, if necessary.
  , pgUsername :: Maybe T.Text
    -- | Password for authentication, if necessary.
  , pgPassword :: Maybe T.Text
  }

-- | Connect to the given database on the given host, on the default PostgreSQL
--   port (5432):
--
-- > withPostgreSQL ("my_db" `on` "example.com") $ do
-- >   ...
on :: T.Text -> T.Text -> PGConnectInfo
on db host = PGConnectInfo
  { pgHost = host
  , pgPort = 5432
  , pgDatabase = db
  , pgUsername = Nothing
  , pgPassword = Nothing
  }
infixl 7 `on`

-- | Add the given username and password to the given connection information:
--
-- > withPostgreSQL ("my_db" `on` "example.com" `auth` ("user", "pass")) $ do
-- >   ...
--
--   For more precise control over the connection options, you should modify
--   the 'PGConnectInfo' directly.
auth :: PGConnectInfo -> (T.Text, T.Text) -> PGConnectInfo
auth ci (user, pass) = ci
  { pgUsername = Just user
  , pgPassword = Just pass
  }
infixl 4 `auth`

-- | Perform the given computation over a PostgreSQL database.
--   The database connection is guaranteed to be closed when the computation
--   terminates.
withPostgreSQL :: (MonadIO m, MonadThrow m, MonadMask m)
               => PGConnectInfo -> SeldaT m a -> m a
withPostgreSQL ci m = do
  conn <- liftIO $ connectdb (pgConnString ci)
  st <- liftIO $ status conn
  case st of
    ConnectionOk -> runSeldaT m (pgBackend conn) `finally` liftIO (finish conn)
    nope         -> connFailed nope
  where
    connFailed f = throwM $ PGConnectException $ unwords
      [ "unable to connect to postgres server: " ++ show f
      ]

pgBackend :: Connection -> SeldaBackend
pgBackend c = SeldaBackend
  { runStmt       = pgQueryRunner c
  , runStmtWithPK = error "runStmtWithPK not supported"
  , customColType = pgColType
  }

pgConnString :: PGConnectInfo -> BS.ByteString
pgConnString PGConnectInfo{..} = mconcat
  [ "host=", encodeUtf8 pgHost, " "
  , "port=", BS.pack (show pgPort), " "
  , "dbname=", encodeUtf8 pgDatabase, " "
  , case pgUsername of
      Just user -> "user=" <> encodeUtf8 user <> " "
      _         -> ""
  , case pgPassword of
      Just pass -> "password=" <> encodeUtf8 pass <> " "
      _         -> ""
  , "connect_timeout=10", " "
  , "client_encoding=UTF8"
  ]

pgQueryRunner :: Connection -> T.Text -> [Param] -> IO (Int, [[SqlValue]])
pgQueryRunner c q ps = do
    mres <- execParams c (encodeUtf8 q) [fromSqlValue p | Param p <- ps] Text
    case mres of
      Just res -> getRows res
      Nothing  -> error "unable to submit query to server!"
  where
    getRows res = do
      rows <- ntuples res
      cols <- nfields res
      types <- mapM (ftype res) [0..cols-1]
      affected <- cmdTuples res
      result <- mapM (getRow res types cols) [0..rows-1]
      pure $ case affected of
        Just "" -> (0, result)
        Just s  -> (read $ BS.unpack s, result)
        _       -> (0, result)

    getRow res types cols row = do
      sequence $ zipWith (getCol res row) [0..cols-1] types

    getCol res row col t = do
      mval <- getvalue res row col
      case mval of
        Just val -> pure $ toSqlValue t val
        _        -> pure SqlNull

-- | Convert the given postgres return value and type to an @SqlValue@.
--   TODO: use binary format instead of text.
toSqlValue :: Oid -> BS.ByteString -> SqlValue
toSqlValue t val
  | t == boolType   = SqlBool $ if read (BS.unpack val) == (0 :: Int) then False else True
  | t == intType    = SqlInt $ read (BS.unpack val)
  | t == doubleType = SqlFloat $ read (BS.unpack val)
  | t == textType   = SqlString (decodeUtf8 val)
  | otherwise       = error $ "result with unknown type oid: " ++ show t

-- | Convert a parameter into an postgres parameter triple.
fromSqlValue :: Lit a -> Maybe (Oid, BS.ByteString, Format)
fromSqlValue (LitB b)    = Just (boolType, if b then "true" else "false", Text)
fromSqlValue (LitI n)    = Just (intType, BS.pack $ show n, Text)
fromSqlValue (LitD f)    = Just (doubleType, BS.pack $ show f, Text)
fromSqlValue (LitS s)    = Just (textType, encodeUtf8 s, Text)
fromSqlValue (LitNull)   = Nothing
fromSqlValue (LitJust x) = fromSqlValue x

-- | Custom column types for postgres: auto-incrementing primary keys need to
--   be @BIGSERIAL@, and ints need to be @INT8@.
pgColType :: T.Text -> [ColAttr] -> Maybe T.Text
pgColType "INTEGER" attrs
  | AutoIncrement `elem` attrs =
    Just "BIGSERIAL PRIMARY KEY NOT NULL"
  | otherwise =
    Just $ T.unwords ("INT8" : map compileColAttr attrs)
pgColType _ _ =
    Nothing

-- | OIDs for all types used by Selda.
boolType, intType, textType, doubleType :: Oid
boolType   = Oid 16
intType    = Oid 20
textType   = Oid 25
doubleType = Oid 701
