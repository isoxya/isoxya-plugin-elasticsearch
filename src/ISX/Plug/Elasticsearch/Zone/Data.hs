module ISX.Plug.Elasticsearch.Zone.Data (
    create,
    ) where


import              Control.Lens
import              Data.Aeson
import              Data.Aeson.Lens
import              Data.Scientific                         (scientific)
import              Data.Time.Clock                         (UTCTime)
import              Network.URI
import              Snap.Core
import              TPX.Com.API.Aeson
import              TPX.Com.API.Req
import              TPX.Com.API.Res
import              TPX.Com.ISX.PlugStrm
import              TPX.Com.ISX.PlugStrmSnap                ()
import              TPX.Com.URI
import qualified    Crypto.Hash                             as  Hash
import qualified    Data.ByteString.Lazy.Char8              as  C8
import qualified    Data.Text                               as  T
import qualified    Data.Time.Format                        as  Time
import qualified    Data.Vector                             as  V
import qualified    Network.HTTP.Conduit                    as  HTTP
import qualified    Network.HTTP.Types.Status               as  HTTP
import qualified    TPX.Com.Net                             as  N


create :: URI -> N.Conn -> Snap ()
create u n = do
    req_      <- getBoundedJSON' reqLim >>= validateJSON
    Just strm <- runValidate req_
    let strms' = convStrm strm
    let resultsN = toInteger $ length strms'
    let uBody = C8.unlines $ concat [[
            encode $ jAction strm i,
            encode $ mergeObject (toJSON strm') $ jDataMeta i resultsN
            ] | (i, strm') <- zip [1..] strms']
    let uReq = N.jsonNDReq $ N.makeReq "POST" reqURL uBody
    uRes <- liftIO $ N.makeRes uReq n
    modifyResponse $ setResponseCode $
        HTTP.statusCode $ HTTP.responseStatus uRes
    writeLBS $ HTTP.responseBody uRes
    where
        Just uPath = parseRelativeReference "/_bulk"
        reqURL = relativeTo uPath u
        reqLim = 2097152 -- 2 MB = (1 + .5) * (4/3) MB


convStrm :: PlugStrm -> [PlugStrm]
convStrm strm = if null r then rDef else r
    where
        datSpellchecker = [mergeObject result $ object [
                ("paragraph", String $ datum ^. key "paragraph" . _String)] |
            datum  <- V.toList $ plugStrmData strm ^. _Array,
            result <- V.toList $ datum ^. key "results" . _Array]
        r = case plugStrmPlugProcTag strm of
            "spellchecker" -> [strm {
                plugStrmData = datum} | datum <- datSpellchecker]
            _ -> rDef
        rDef = [strm]

dId :: PlugStrm -> Integer -> Text
dId strm i = show _idh <> "." <> show i
    where
        _idh = hash (plugStrmCrwlHref strm <> "|" <>
            show (unURIAbsolute $ plugStrmURL strm) <> "|" <>
            plugStrmPlugProcHref strm)

dIndex :: PlugStrm -> Maybe Text
dIndex strm = do
    org <- unOrgHref $ plugStrmOrgHref strm
    let time = plugStrmCrwlTBegin strm
    return $ _ns <> _sep <> org <> _sep <> formatTime time
    where
        _sep = "."
        _ns = "isoxya" :: Text

formatTime :: UTCTime -> Text
formatTime = toText . Time.formatTime Time.defaultTimeLocale "%F"

hash :: Text -> Hash.Digest Hash.SHA256
hash t = Hash.hash (encodeUtf8 t :: ByteString)

jAction :: PlugStrm -> Integer -> Maybe Value
jAction strm i = do
    dIndex' <- dIndex strm
    return $ object [
        ("index", object [
            ("_index", String dIndex'),
            ("_id", String $ dId strm i)])]

jDataMeta :: Integer -> Integer -> Value
jDataMeta i n = object [
    ("data_i", Number $ scientific i 0),
    ("data_n", Number $ scientific n 0)]

unOrgHref :: Text -> Maybe Text
unOrgHref h = do
    ["", "org", o] <- return $ T.splitOn "/" h
    return o