{-# LANGUAGE OverloadedStrings #-}

module PostgREST.OpenAPI (
  encodeOpenAPI
  , isMalformedProxyUri
  , pickProxy
  ) where

import           Control.Lens
import           Data.Aeson                  (decode, encode)
import           Data.ByteString.Lazy        (ByteString)
import           Data.HashMap.Strict.InsOrd  (InsOrdHashMap, fromList)
import           Data.Maybe                  (isJust, isNothing, fromJust)
import           Data.String                 (IsString (..))
import           Data.Text                   (Text, unpack, pack, concat, intercalate, init, tail, toLower)
import qualified Data.Set                    as Set
import           Network.URI                 (parseURI, isAbsoluteURI,
                                              URI (..), URIAuth (..))

import           Prelude hiding              (concat, init, tail)

import           Data.Swagger

import           PostgREST.ApiRequest        (ContentType(..))
import           PostgREST.Config            (prettyVersion)
import           PostgREST.QueryBuilder      (operators)
import           PostgREST.Types             (Table(..), Column(..),
                                              Proxy(..))

makeMimeList :: [ContentType] -> MimeList
makeMimeList cs = MimeList $ map (fromString . show) cs

toSwaggerType :: Text -> SwaggerType t
toSwaggerType "text"      = SwaggerString
toSwaggerType "integer"   = SwaggerInteger
toSwaggerType "boolean"   = SwaggerBoolean
toSwaggerType "numeric"   = SwaggerNumber
toSwaggerType _           = SwaggerString

makeProperty :: Column -> (Text, Referenced Schema)
makeProperty c = (colName c, Inline u)
  where
    r = mempty :: Schema
    s = if null $ colEnum c
           then r
           else r & enum_ .~ decode (encode (colEnum c))
    t = s & type_ .~ toSwaggerType (colType c)
    u = t & format ?~ colType c

makeProperties :: [Column] -> InsOrdHashMap Text (Referenced Schema)
makeProperties cs =  fromList $ map makeProperty cs

makeDefinition :: (Table, [Column], [Text]) -> (Text, Schema)
makeDefinition (t, cs, _) =
  let tn = tableName t in
      (tn, (mempty :: Schema)
        & type_ .~ SwaggerObject
        & properties .~ makeProperties cs)

makeDefinitions :: [(Table, [Column], [Text])] -> InsOrdHashMap Text Schema
makeDefinitions ti = fromList $ map makeDefinition ti

makeOperatorPattern :: Text
makeOperatorPattern =
  intercalate "|"
  [ concat ["^", x, y, "[.]"] |
    x <- ["not[.]", ""],
    y <- map fst operators ]

makeRowFilter :: Column -> Param
makeRowFilter c =
  (mempty :: Param)
  & name .~ colName c
  & required ?~ False
  & schema .~ ParamOther ((mempty :: ParamOtherSchema)
    & in_ .~ ParamQuery
    & type_ .~ SwaggerString
    & format ?~ colType c
    & pattern ?~ makeOperatorPattern)

makeRowFilters :: [Column] -> [Param]
makeRowFilters = map makeRowFilter

makeOrderItems :: [Column] -> [Text]
makeOrderItems cs =
  [ concat [x, y, z] |
    x <- map colName cs,
    y <- [".asc", ".desc", ""],
    z <- [".nullsfirst", ".nulllast", ""]
  ]

makeRangeParams :: [Param]
makeRangeParams =
  [ (mempty :: Param)
    & name        .~ "Range"
    & description ?~ "Limiting and Pagination"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamHeader
      & type_ .~ SwaggerString)
  , (mempty :: Param)
    & name        .~ "Range-Unit"
    & description ?~ "Limiting and Pagination"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamHeader
      & type_ .~ SwaggerString
      & default_ .~ decode "\"items\"")
  , (mempty :: Param)
    & name        .~ "offset"
    & description ?~ "Limiting and Pagination"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamQuery
      & type_ .~ SwaggerString)
  , (mempty :: Param)
    & name        .~ "limit"
    & description ?~ "Limiting and Pagination"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamQuery
      & type_ .~ SwaggerString)
  ]

makePreferParam :: [Text] -> Param
makePreferParam ts =
  (mempty :: Param)
  & name        .~ "Prefer"
  & description ?~ "Preference"
  & required    ?~ False
  & schema .~ ParamOther ((mempty :: ParamOtherSchema)
    & in_ .~ ParamHeader
    & type_ .~ SwaggerString
    & enum_ .~ decode (encode ts))

makeSelectParam :: Param
makeSelectParam =
  (mempty :: Param)
    & name        .~ "select"
    & description ?~ "Filtering Columns"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamQuery
      & type_ .~ SwaggerString)

makeGetParams :: [Column] -> [Param]
makeGetParams [] =
  makeRangeParams ++
  [ makeSelectParam
  , makePreferParam ["plurality=singular", "count=none"]
  ]
makeGetParams cs =
  makeRangeParams ++
  [ makeSelectParam
  , (mempty :: Param)
    & name        .~ "order"
    & description ?~ "Ordering"
    & required    ?~ False
    & schema .~ ParamOther ((mempty :: ParamOtherSchema)
      & in_ .~ ParamQuery
      & type_ .~ SwaggerString
      & enum_ .~ decode (encode $ makeOrderItems cs))
  , makePreferParam ["plurality=singular", "count=none"]
  ]

makeReturnPreferenceParam :: Param
makeReturnPreferenceParam =
  makePreferParam ["return=representation", "return=minimal", "return=none"]

makePostParams :: Text -> [Param]
makePostParams tn =
  [ makeReturnPreferenceParam
  , (mempty :: Param)
    & name        .~ "body"
    & description ?~ tn
    & required    ?~ False
    & schema .~ ParamBody (Ref (Reference tn))
  ]

makeDeleteParams :: [Param]
makeDeleteParams =
  [ makeReturnPreferenceParam ]

makePathItem :: (Table, [Column], [Text]) -> (FilePath, PathItem)
makePathItem (t, cs, _) = ("/" ++ unpack tn, p $ tableInsertable t)
  where
    tOp = (mempty :: Operation)
      & tags .~ Set.fromList [tn]
      & produces ?~ makeMimeList [ApplicationJSON, TextCSV]
      & at 200 ?~ "OK"
    getOp = tOp
      & parameters .~ map Inline (makeGetParams cs ++ rs)
      & at 206 ?~ "Partial Content"
    postOp = tOp
      & consumes ?~ makeMimeList [ApplicationJSON, TextCSV]
      & parameters .~ map Inline (makePostParams tn)
      & at 201 ?~ "Created"
    patchOp = tOp
      & consumes ?~ makeMimeList [ApplicationJSON, TextCSV]
      & parameters .~ map Inline (makePostParams tn ++ rs)
      & at 204 ?~ "No Content"
    deletOp = tOp
      & parameters .~ map Inline (makeDeleteParams ++ rs)
    pr = (mempty :: PathItem) & get ?~ getOp
    pw = pr & post ?~ postOp & patch ?~ patchOp & delete ?~ deletOp
    p False = pr
    p True  = pw
    rs = makeRowFilters cs
    tn = tableName t

makeRootPathItem :: (FilePath, PathItem)
makeRootPathItem = ("/", p)
  where
    getOp = (mempty :: Operation)
      & tags .~ Set.fromList ["/"]
      & produces ?~ makeMimeList [ApplicationJSON, OpenAPI]
      & at 200 ?~ "OK"
    pr = (mempty :: PathItem) & get ?~ getOp
    p = pr

makePathItems :: [(Table, [Column], [Text])] -> InsOrdHashMap FilePath PathItem
makePathItems ti = fromList $ makeRootPathItem : map makePathItem ti

escapeHostName :: Text -> Text
escapeHostName "*"  = "0.0.0.0"
escapeHostName "*4" = "0.0.0.0"
escapeHostName "!4" = "0.0.0.0"
escapeHostName "*6" = "0.0.0.0"
escapeHostName "!6" = "0.0.0.0"
escapeHostName h    = h

postgrestSpec:: [(Table, [Column], [Text])] -> (Text, Text, Integer, Text) -> Swagger
postgrestSpec ti (s, h, p, b) = (mempty :: Swagger)
  & basePath ?~ unpack b
  & schemes ?~ [s']
  & info .~ ((mempty :: Info)
      & version .~ pack prettyVersion
      & title .~ "PostgREST API"
      & description ?~ "This is a dynamic API generated by PostgREST")
  & host .~ h'
  & definitions .~ makeDefinitions ti
  & paths .~ makePathItems ti
    where
      s' = if s == "http" then Http else Https
      h' = Just $ Host (unpack $ escapeHostName h) (Just (fromInteger p))

encodeOpenAPI :: [(Table, [Column], [Text])] -> (Text, Text, Integer, Text) -> ByteString
encodeOpenAPI ti uri = encode $ postgrestSpec ti uri

{-|
  Test whether a proxy uri is malformed or not.
  A valid proxy uri should be an absolute uri without query and user info,
  only http(s) schemes are valid, port number range is 1-65535.

  For example
  http://postgrest.com/openapi.json
  https://postgrest.com:8080/openapi.json
-}
isMalformedProxyUri :: Maybe String -> Bool
isMalformedProxyUri Nothing =  False
isMalformedProxyUri (Just uri)
  | isAbsoluteURI uri = not $ isUriValid $ toURI uri
  | otherwise = True

toURI :: String -> URI
toURI uri = fromJust $ parseURI uri

pickProxy :: Maybe String -> Maybe Proxy
pickProxy proxy
  | isNothing proxy = Nothing
  -- should never happen
  -- since the request would have been rejected by the middleware if proxy uri
  -- is malformed
  | isMalformedProxyUri proxy = Nothing
  | otherwise = Just Proxy {
    proxyScheme = scheme
  , proxyHost = host'
  , proxyPort = port''
  , proxyPath = path'
  }
 where
   uri = toURI $ fromJust proxy
   scheme = init $ toLower $ pack $ uriScheme uri
   path URI {uriPath = ""} =  "/"
   path URI {uriPath = p} = p
   path' = pack $ path uri
   authority = fromJust $ uriAuthority uri
   host' = pack $ uriRegName authority
   port' = uriPort authority
   port'' :: Integer
   port'' = case (port', scheme) of
             ("", "http") -> 80
             ("", "https") -> 443
             _ -> read $ unpack $ tail $ pack port'

isUriValid:: URI -> Bool
isUriValid = fAnd [isSchemeValid, isQueryValid, isAuthorityValid]

fAnd :: [a -> Bool] -> a -> Bool
fAnd fs x = all ($x) fs

isSchemeValid :: URI -> Bool
isSchemeValid URI {uriScheme = s}
  | toLower (pack s) == "https:" = True
  | toLower (pack s) == "http:" = True
  | otherwise = False

isQueryValid :: URI -> Bool
isQueryValid URI {uriQuery = ""} = True
isQueryValid _ = False

isAuthorityValid :: URI -> Bool
isAuthorityValid URI {uriAuthority = a}
  | isJust a = fAnd [isUserInfoValid, isHostValid, isPortValid] $ fromJust a
  | otherwise = False

isUserInfoValid :: URIAuth -> Bool
isUserInfoValid URIAuth {uriUserInfo = ""} = True
isUserInfoValid _ = False

isHostValid :: URIAuth -> Bool
isHostValid URIAuth {uriRegName = ""} = False
isHostValid _ = True

isPortValid :: URIAuth -> Bool
isPortValid URIAuth {uriPort = ""} = True
isPortValid URIAuth {uriPort = (':':p)} =
  let i :: Integer = read p in
      i > 0 && i < 65536
isPortValid _ = False
