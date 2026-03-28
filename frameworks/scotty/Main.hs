{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Web.Scotty
import Network.Wai (rawQueryString, requestMethod, requestHeaders)
import Network.Wai.Handler.Warp (defaultSettings, setPort)
import Network.HTTP.Types.Status (status404, status500)
import Network.HTTP.Types.Method (methodPost)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Encoding as TE
import Data.Aeson (FromJSON, Value(..), encode, eitherDecodeStrict, object, (.=), (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson

import qualified Codec.Compression.GZip as GZip
import qualified Codec.Compression.Zlib as Zlib

import qualified Database.SQLite.Simple as SQLite
import qualified Database.PostgreSQL.Simple as PG

import Data.IORef
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Char (isSpace)
import qualified Data.Map.Strict as Map
import System.Environment (lookupEnv)
import System.Directory (doesFileExist, doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Control.Monad (when, forM)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (try, SomeException, bracket)
import Text.Read (readMaybe)

-- Dataset item as loaded from JSON
data DatasetItem = DatasetItem
  { diId       :: !Int
  , diName     :: !T.Text
  , diCategory :: !T.Text
  , diPrice    :: !Double
  , diQuantity :: !Int
  , diActive   :: !Bool
  , diTags     :: ![T.Text]
  , diRating   :: !RatingVal
  } deriving (Show)

data RatingVal = RatingVal
  { rvScore :: !Double
  , rvCount :: !Int
  } deriving (Show)

instance FromJSON RatingVal where
  parseJSON = Aeson.withObject "RatingVal" $ \v ->
    RatingVal <$> v .: "score" <*> v .: "count"

instance FromJSON DatasetItem where
  parseJSON = Aeson.withObject "DatasetItem" $ \v ->
    DatasetItem
      <$> v .: "id"
      <*> v .: "name"
      <*> v .: "category"
      <*> v .: "price"
      <*> v .: "quantity"
      <*> v .: "active"
      <*> v .: "tags"
      <*> v .: "rating"

-- Build processed JSON Value from DatasetItem (with total field)
processedItemValue :: DatasetItem -> Value
processedItemValue di = object
  [ "id"       .= diId di
  , "name"     .= diName di
  , "category" .= diCategory di
  , "price"    .= diPrice di
  , "quantity" .= diQuantity di
  , "active"   .= diActive di
  , "tags"     .= diTags di
  , "rating"   .= object ["score" .= rvScore (diRating di), "count" .= rvCount (diRating di)]
  , "total"    .= (fromIntegral (round (diPrice di * fromIntegral (diQuantity di) * 100) :: Int) / 100.0 :: Double)
  ]

-- Parse query string: "?a=1&b=2" -> sum of integer values
parseQuerySum :: BS.ByteString -> Int
parseQuerySum qs =
  let qs' = if not (BS.null qs) && BS.head qs == 63 {- '?' -} then BS.drop 1 qs else qs
      pairs = BC.split '&' qs'
      parseVal pair = case BC.split '=' pair of
        [_, v] -> readMaybe (BC.unpack v) :: Maybe Int
        _      -> Nothing
  in sum $ mapMaybe parseVal pairs

-- MIME type lookup
mimeForExt :: String -> BS.ByteString
mimeForExt ".css"   = "text/css"
mimeForExt ".js"    = "application/javascript"
mimeForExt ".html"  = "text/html"
mimeForExt ".woff2" = "font/woff2"
mimeForExt ".svg"   = "image/svg+xml"
mimeForExt ".webp"  = "image/webp"
mimeForExt ".json"  = "application/json"
mimeForExt _        = "application/octet-stream"

main :: IO ()
main = do
  -- Load dataset
  datasetPath <- fromMaybe "/data/dataset.json" <$> lookupEnv "DATASET_PATH"
  datasetItems <- do
    exists <- doesFileExist datasetPath
    if exists
      then do
        raw <- BS.readFile datasetPath
        case eitherDecodeStrict raw of
          Right items -> return (items :: [DatasetItem])
          Left _      -> return []
      else return []

  -- Pre-compute large JSON payload for compression endpoint
  largePayload <- do
    exists <- doesFileExist "/data/dataset-large.json"
    if exists
      then do
        raw <- BS.readFile "/data/dataset-large.json"
        case eitherDecodeStrict raw of
          Right items -> do
            let processed = map processedItemValue (items :: [DatasetItem])
                resp = encode $ object ["items" .= processed, "count" .= length processed]
            return (Just (BL.toStrict resp))
          Left _ -> return Nothing
      else return Nothing

  -- Load static files into memory
  staticCache <- do
    let dir = "/data/static"
    exists <- doesDirectoryExist dir
    if exists
      then do
        files <- listDirectory dir
        entries <- forM files $ \name -> do
          content <- BS.readFile (dir </> name)
          let ct = mimeForExt (takeExtension name)
          return (name, (content, ct))
        return (Map.fromList entries)
      else return Map.empty

  -- SQLite connection (read-only)
  dbRef <- newIORef (Nothing :: Maybe SQLite.Connection)
  do
    exists <- doesFileExist "/data/benchmark.db"
    when exists $ do
      conn <- SQLite.open "/data/benchmark.db"
      SQLite.execute_ conn "PRAGMA mmap_size=268435456"
      writeIORef dbRef (Just conn)

  -- Postgres URL
  pgUrl <- lookupEnv "DATABASE_URL"

  let opts = Options 0 (setPort 8080 defaultSettings) False

  scottyOpts opts $ do

    -- Pipeline test: GET /pipeline -> "ok"
    get "/pipeline" $ do
      setHeader "Server" "scotty"
      text "ok"

    -- Baseline HTTP/1.1: GET|POST /baseline11
    let handleBaseline = do
          req <- request
          let qSum = parseQuerySum (rawQueryString req)
          bodySum <- if requestMethod req == methodPost
            then do
              b <- body
              let trimmed = BLC.dropWhile isSpace b
              return $ fromMaybe 0 (readMaybe (BLC.unpack trimmed) :: Maybe Int)
            else return 0
          setHeader "Server" "scotty"
          text $ TL.pack $ show (qSum + bodySum)

    get "/baseline11" handleBaseline
    post "/baseline11" handleBaseline

    -- Baseline HTTP/2: GET /baseline2
    get "/baseline2" $ do
      req <- request
      let qSum = parseQuerySum (rawQueryString req)
      setHeader "Server" "scotty"
      text $ TL.pack $ show qSum

    -- JSON processing: GET /json
    get "/json" $ do
      let items = map processedItemValue datasetItems
          resp = encode $ object ["items" .= items, "count" .= length items]
      setHeader "Server" "scotty"
      setHeader "Content-Type" "application/json"
      raw resp

    -- Compression: GET /compression
    get "/compression" $ do
      case largePayload of
        Nothing -> do
          status status500
          text "No dataset"
        Just payload -> do
          req <- request
          let ae = fromMaybe "" $ lookup "Accept-Encoding" (requestHeaders req)
          setHeader "Server" "scotty"
          setHeader "Content-Type" "application/json"
          if "deflate" `BS.isInfixOf` ae
            then do
              setHeader "Content-Encoding" "deflate"
              raw $ Zlib.compressWith
                Zlib.defaultCompressParams { Zlib.compressLevel = Zlib.bestSpeed }
                (BL.fromStrict payload)
            else if "gzip" `BS.isInfixOf` ae
              then do
                setHeader "Content-Encoding" "gzip"
                raw $ GZip.compressWith
                  GZip.defaultCompressParams { GZip.compressLevel = GZip.bestSpeed }
                  (BL.fromStrict payload)
              else raw (BL.fromStrict payload)

    -- Upload: POST /upload -> byte count
    post "/upload" $ do
      b <- body
      setHeader "Server" "scotty"
      text $ TL.pack $ show (BL.length b)

    -- SQLite DB: GET /db
    get "/db" $ do
      mConn <- liftIO $ readIORef dbRef
      case mConn of
        Nothing -> do
          setHeader "Server" "scotty"
          setHeader "Content-Type" "application/json"
          raw "{\"items\":[],\"count\":0}"
        Just conn -> do
          minP <- paramWithDefault "min" 10.0
          maxP <- paramWithDefault "max" 50.0
          rows <- liftIO $ SQLite.query conn
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50"
            (minP :: Double, maxP :: Double)
          let items = map sqliteRowToValue rows
              resp = encode $ object ["items" .= items, "count" .= length items]
          setHeader "Server" "scotty"
          setHeader "Content-Type" "application/json"
          raw resp

    -- Async DB (PostgreSQL): GET /async-db
    get "/async-db" $ do
      setHeader "Server" "scotty"
      setHeader "Content-Type" "application/json"
      case pgUrl of
        Nothing -> raw "{\"items\":[],\"count\":0}"
        Just url -> do
          minP <- paramWithDefault "min" 10.0
          maxP <- paramWithDefault "max" 50.0
          result <- liftIO $ try $ bracket
            (PG.connectPostgreSQL (BC.pack url))
            PG.close
            (\conn -> PG.query conn
              "SELECT id, name, category, price, quantity, active, tags::text, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50"
              (minP :: Double, maxP :: Double))
          case result of
            Left (_ :: SomeException) -> raw "{\"items\":[],\"count\":0}"
            Right rows -> do
              let items = map pgRowToValue rows
              raw $ encode $ object ["items" .= items, "count" .= length items]

    -- Static files: GET /static/:filename
    get "/static/:filename" $ do
      filename <- pathParam "filename" :: ActionM T.Text
      let key = T.unpack filename
      case Map.lookup key staticCache of
        Just (content, ct) -> do
          setHeader "Server" "scotty"
          setHeader "Content-Type" (TL.fromStrict (TE.decodeUtf8 ct))
          raw (BL.fromStrict content)
        Nothing -> do
          status status404
          text "Not Found"

-- Helper: get query parameter with default
paramWithDefault :: String -> Double -> ActionM Double
paramWithDefault name def = do
  mv <- queryParamMaybe (TL.pack name)
  case mv of
    Nothing -> return def
    Just v  -> return $ fromMaybe def (readMaybe (TL.unpack v) :: Maybe Double)

-- Convert SQLite row to JSON Value
sqliteRowToValue :: (Int, T.Text, T.Text, Double, Int, Int, T.Text, Double, Int) -> Value
sqliteRowToValue (rid, name, category, price, quantity, active, tagsJson, rScore, rCount) =
  let tags = fromMaybe ([] :: [T.Text]) (Aeson.decodeStrict (TE.encodeUtf8 tagsJson))
  in object
    [ "id"       .= rid
    , "name"     .= name
    , "category" .= category
    , "price"    .= price
    , "quantity" .= quantity
    , "active"   .= (active == 1)
    , "tags"     .= tags
    , "rating"   .= object ["score" .= rScore, "count" .= rCount]
    ]

-- Convert PostgreSQL row to JSON Value
pgRowToValue :: (Int, T.Text, T.Text, Double, Int, Bool, T.Text, Double, Int) -> Value
pgRowToValue (rid, name, category, price, quantity, active, tagsJson, rScore, rCount) =
  let tags = fromMaybe ([] :: [Value]) (Aeson.decodeStrict (TE.encodeUtf8 tagsJson))
  in object
    [ "id"       .= rid
    , "name"     .= name
    , "category" .= category
    , "price"    .= price
    , "quantity" .= quantity
    , "active"   .= active
    , "tags"     .= tags
    , "rating"   .= object ["score" .= rScore, "count" .= rCount]
    ]
