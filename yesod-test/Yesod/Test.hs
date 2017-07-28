{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ConstraintKinds #-}

{-|
Yesod.Test is a pragmatic framework for testing web applications built
using wai and persistent.

By pragmatic I may also mean 'dirty'. Its main goal is to encourage integration
and system testing of web applications by making everything /easy to test/.

Your tests are like browser sessions that keep track of cookies and the last
visited page. You can perform assertions on the content of HTML responses,
using CSS selectors to explore the document more easily.

You can also easily build requests using forms present in the current page.
This is very useful for testing web applications built in yesod, for example,
where your forms may have field names generated by the framework or a randomly
generated CSRF token input.

Your database is also directly available so you can use 'runDB' to set up
backend pre-conditions, or to assert that your session is having the desired effect.

-}

module Yesod.Test
    ( -- * Declaring and running your test suite
      yesodSpec
    , YesodSpec
    , yesodSpecWithSiteGenerator
    , yesodSpecApp
    , YesodExample
    , YesodExampleData(..)
    , TestApp
    , YSpec
    , testApp
    , YesodSpecTree (..)
    , ydescribe
    , yit

    -- * Making requests
    -- | You can construct requests with the 'RequestBuilder' monad, which lets you
    -- set the URL and add parameters, headers, and files. Helper functions are provided to
    -- lookup fields by label and to add the current CSRF token from your forms.
    -- Once built, the request can be executed with the 'request' method.
    --
    -- Convenience functions like 'get' and 'post' build and execute common requests.
    , get
    , post
    , postBody
    , followRedirect
    , getLocation
    , request
    , addRequestHeader
    , setMethod
    , addPostParam
    , addGetParam
    , addFile
    , setRequestBody
    , RequestBuilder
    , setUrl
    , clickOn

    -- *** Adding fields by label
    -- | Yesod can auto generate field names, so you are never sure what
    -- the argument name should be for each one of your inputs when constructing
    -- your requests. What you do know is the /label/ of the field.
    -- These functions let you add parameters to your request based
    -- on currently displayed label names.
    , byLabel
    , fileByLabel

    -- *** CSRF Tokens
    -- | In order to prevent CSRF exploits, yesod-form adds a hidden input
    -- to your forms with the name "_token". This token is a randomly generated,
    -- per-session value.
    --
    -- In order to prevent your forms from being rejected in tests, use one of
    -- these functions to add the token to your request.
    , addToken
    , addToken_
    , addTokenFromCookie
    , addTokenFromCookieNamedToHeaderNamed

    -- * Assertions
    , assertEqual
    , assertNotEq
    , assertEqualNoShow
    , assertEq

    , assertHeader
    , assertNoHeader
    , statusIs
    , bodyEquals
    , bodyContains
    , bodyNotContains
    , htmlAllContain
    , htmlAnyContain
    , htmlNoneContain
    , htmlCount

    -- * Grab information
    , getTestYesod
    , getResponse
    , getRequestCookies

    -- * Debug output
    , printBody
    , printMatches

    -- * Utils for building your own assertions
    -- | Please consider generalizing and contributing the assertions you write.
    , htmlQuery
    , parseHTML
    , withResponse
    ) where

import qualified Test.Hspec.Core.Spec as Hspec
import qualified Data.List as DL
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString (ByteString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Test.HUnit as HUnit
import qualified Network.HTTP.Types as H
import qualified Network.Socket.Internal as Sock
import Data.CaseInsensitive (CI)
import Network.Wai
import Network.Wai.Test hiding (assertHeader, assertNoHeader, request)
import qualified Control.Monad.Trans.State as ST
import Control.Monad.IO.Class
import System.IO
import Yesod.Core.Unsafe (runFakeHandler)
import Yesod.Test.TransversingCSS
import Yesod.Core
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Encoding (encodeUtf8, decodeUtf8)
import Text.XML.Cursor hiding (element)
import qualified Text.XML.Cursor as C
import qualified Text.HTML.DOM as HD
import Control.Monad.Trans.Writer
import qualified Data.Map as M
import qualified Web.Cookie as Cookie
import qualified Blaze.ByteString.Builder as Builder
import Data.Time.Clock (getCurrentTime)
import Control.Applicative ((<$>))
import Text.Show.Pretty (ppShow)
import Data.Monoid (mempty)
#if MIN_VERSION_base(4,9,0)
import GHC.Stack (HasCallStack)
#elif MIN_VERSION_base(4,8,1)
import GHC.Stack (CallStack)
type HasCallStack = (?callStack :: CallStack)
#else
import GHC.Exts (Constraint)
type HasCallStack = (() :: Constraint)
#endif


-- | The state used in a single test case defined using 'yit'
--
-- Since 1.2.4
data YesodExampleData site = YesodExampleData
    { yedApp :: !Application
    , yedSite :: !site
    , yedCookies :: !Cookies
    , yedResponse :: !(Maybe SResponse)
    }

-- | A single test case, to be run with 'yit'.
--
-- Since 1.2.0
type YesodExample site = ST.StateT (YesodExampleData site) IO

-- | Mapping from cookie name to value.
--
-- Since 1.2.0
type Cookies = M.Map ByteString Cookie.SetCookie

-- | Corresponds to hspec\'s 'Spec'.
--
-- Since 1.2.0
type YesodSpec site = Writer [YesodSpecTree site] ()

-- | Internal data structure, corresponding to hspec\'s 'YesodSpecTree'.
--
-- Since 1.2.0
data YesodSpecTree site
    = YesodSpecGroup String [YesodSpecTree site]
    | YesodSpecItem String (YesodExample site ())

-- | Get the foundation value used for the current test.
--
-- Since 1.2.0
getTestYesod :: YesodExample site site
getTestYesod = fmap yedSite ST.get

-- | Get the most recently provided response value, if available.
--
-- Since 1.2.0
getResponse :: YesodExample site (Maybe SResponse)
getResponse = fmap yedResponse ST.get

data RequestBuilderData site = RequestBuilderData
    { rbdPostData :: RBDPostData
    , rbdResponse :: (Maybe SResponse)
    , rbdMethod :: H.Method
    , rbdSite :: site
    , rbdPath :: [T.Text]
    , rbdGets :: H.Query
    , rbdHeaders :: H.RequestHeaders
    }

data RBDPostData = MultipleItemsPostData [RequestPart]
                 | BinaryPostData BSL8.ByteString

-- | Request parts let us discern regular key/values from files sent in the request.
data RequestPart
  = ReqKvPart T.Text T.Text
  | ReqFilePart T.Text FilePath BSL8.ByteString T.Text

-- | The 'RequestBuilder' state monad constructs a URL encoded string of arguments
-- to send with your requests. Some of the functions that run on it use the current
-- response to analyze the forms that the server is expecting to receive.
type RequestBuilder site = ST.StateT (RequestBuilderData site) IO

-- | Start describing a Tests suite keeping cookies and a reference to the tested 'Application'
-- and 'ConnectionPool'
ydescribe :: String -> YesodSpec site -> YesodSpec site
ydescribe label yspecs = tell [YesodSpecGroup label $ execWriter yspecs]

yesodSpec :: YesodDispatch site
          => site
          -> YesodSpec site
          -> Hspec.Spec
yesodSpec site yspecs =
    Hspec.fromSpecList $ map unYesod $ execWriter yspecs
  where
    unYesod (YesodSpecGroup x y) = Hspec.specGroup x $ map unYesod y
    unYesod (YesodSpecItem x y) = Hspec.specItem x $ do
        app <- toWaiAppPlain site
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Same as yesodSpec, but instead of taking already built site it
-- takes an action which produces site for each test.
yesodSpecWithSiteGenerator :: YesodDispatch site
                           => IO site
                           -> YesodSpec site
                           -> Hspec.Spec
yesodSpecWithSiteGenerator getSiteAction yspecs =
    Hspec.fromSpecList $ map (unYesod getSiteAction) $ execWriter yspecs
    where
      unYesod getSiteAction' (YesodSpecGroup x y) = Hspec.specGroup x $ map (unYesod getSiteAction') y
      unYesod getSiteAction' (YesodSpecItem x y) = Hspec.specItem x $ do
        site <- getSiteAction'
        app <- toWaiAppPlain site
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Same as yesodSpec, but instead of taking a site it
-- takes an action which produces the 'Application' for each test.
-- This lets you use your middleware from makeApplication
yesodSpecApp :: YesodDispatch site
             => site
             -> IO Application
             -> YesodSpec site
             -> Hspec.Spec
yesodSpecApp site getApp yspecs =
    Hspec.fromSpecList $ map unYesod $ execWriter yspecs
  where
    unYesod (YesodSpecGroup x y) = Hspec.specGroup x $ map unYesod y
    unYesod (YesodSpecItem x y) = Hspec.specItem x $ do
        app <- getApp
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Describe a single test that keeps cookies, and a reference to the last response.
yit :: String -> YesodExample site () -> YesodSpec site
yit label example = tell [YesodSpecItem label example]

-- Performs a given action using the last response. Use this to create
-- response-level assertions
withResponse' :: MonadIO m
              => (state -> Maybe SResponse)
              -> [T.Text]
              -> (SResponse -> ST.StateT state m a)
              -> ST.StateT state m a
withResponse' getter errTrace f = maybe err f . getter =<< ST.get
 where err = failure msg
       msg = if null errTrace
             then "There was no response, you should make a request."
             else
               "There was no response, you should make a request. A response was needed because: \n - "
               <> T.intercalate "\n - " errTrace

-- | Performs a given action using the last response. Use this to create
-- response-level assertions
withResponse :: (SResponse -> YesodExample site a) -> YesodExample site a
withResponse = withResponse' yedResponse []

-- | Use HXT to parse a value from an HTML tag.
-- Check for usage examples in this module's source.
parseHTML :: HtmlLBS -> Cursor
parseHTML html = fromDocument $ HD.parseLBS html

-- | Query the last response using CSS selectors, returns a list of matched fragments
htmlQuery' :: MonadIO m
           => (state -> Maybe SResponse)
           -> [T.Text]
           -> Query
           -> ST.StateT state m [HtmlLBS]
htmlQuery' getter errTrace query = withResponse' getter ("Tried to invoke htmlQuery' in order to read HTML of a previous response." : errTrace) $ \ res ->
  case findBySelector (simpleBody res) query of
    Left err -> failure $ query <> " did not parse: " <> T.pack (show err)
    Right matches -> return $ map (encodeUtf8 . TL.pack) matches

-- | Query the last response using CSS selectors, returns a list of matched fragments
htmlQuery :: Query -> YesodExample site [HtmlLBS]
htmlQuery = htmlQuery' yedResponse []

-- | Asserts that the two given values are equal.
--
-- In case they are not equal, error mesasge includes the two values.
--
-- @since 1.5.2
assertEq :: (HasCallStack, Eq a, Show a) => String -> a -> a -> YesodExample site ()
assertEq m a b =
  liftIO $ HUnit.assertBool msg (a == b)
  where msg = "Assertion: " ++ m ++ "\n" ++
              "First argument:  " ++ ppShow a ++ "\n" ++
              "Second argument: " ++ ppShow b ++ "\n"

-- | Asserts that the two given values are not equal.
--
-- In case they are equal, error mesasge includes the values.
--
-- @since 1.5.6
assertNotEq :: (HasCallStack, Eq a, Show a) => String -> a -> a -> YesodExample site ()
assertNotEq m a b =
  liftIO $ HUnit.assertBool msg (a /= b)
  where msg = "Assertion: " ++ m ++ "\n" ++
              "Both arguments:  " ++ ppShow a ++ "\n"

{-# DEPRECATED assertEqual "Use assertEq instead" #-}
assertEqual :: (HasCallStack, Eq a) => String -> a -> a -> YesodExample site ()
assertEqual = assertEqualNoShow

-- | Asserts that the two given values are equal.
--
-- @since 1.5.2
assertEqualNoShow :: (HasCallStack, Eq a) => String -> a -> a -> YesodExample site ()
assertEqualNoShow msg a b = liftIO $ HUnit.assertBool msg (a == b)

-- | Assert the last response status is as expected.
statusIs :: HasCallStack => Int -> YesodExample site ()
statusIs number = withResponse $ \ SResponse { simpleStatus = s } ->
  liftIO $ flip HUnit.assertBool (H.statusCode s == number) $ concat
    [ "Expected status was ", show number
    , " but received status was ", show $ H.statusCode s
    ]

-- | Assert the given header key/value pair was returned.
assertHeader :: HasCallStack => CI BS8.ByteString -> BS8.ByteString -> YesodExample site ()
assertHeader header value = withResponse $ \ SResponse { simpleHeaders = h } ->
  case lookup header h of
    Nothing -> failure $ T.pack $ concat
        [ "Expected header "
        , show header
        , " to be "
        , show value
        , ", but it was not present"
        ]
    Just value' -> liftIO $ flip HUnit.assertBool (value == value') $ concat
        [ "Expected header "
        , show header
        , " to be "
        , show value
        , ", but received "
        , show value'
        ]

-- | Assert the given header was not included in the response.
assertNoHeader :: HasCallStack => CI BS8.ByteString -> YesodExample site ()
assertNoHeader header = withResponse $ \ SResponse { simpleHeaders = h } ->
  case lookup header h of
    Nothing -> return ()
    Just s  -> failure $ T.pack $ concat
        [ "Unexpected header "
        , show header
        , " containing "
        , show s
        ]

-- | Assert the last response is exactly equal to the given text. This is
-- useful for testing API responses.
bodyEquals :: HasCallStack => String -> YesodExample site ()
bodyEquals text = withResponse $ \ res ->
  liftIO $ HUnit.assertBool ("Expected body to equal " ++ text) $
    (simpleBody res) == encodeUtf8 (TL.pack text)

-- | Assert the last response has the given text. The check is performed using the response
-- body in full text form.
bodyContains :: HasCallStack => String -> YesodExample site ()
bodyContains text = withResponse $ \ res ->
  liftIO $ HUnit.assertBool ("Expected body to contain " ++ text) $
    (simpleBody res) `contains` text

-- | Assert the last response doesn't have the given text. The check is performed using the response
-- body in full text form.
-- @since 1.5.3
bodyNotContains :: HasCallStack => String -> YesodExample site ()
bodyNotContains text = withResponse $ \ res ->
  liftIO $ HUnit.assertBool ("Expected body not to contain " ++ text) $
    not $ contains (simpleBody res) text

contains :: BSL8.ByteString -> String -> Bool
contains a b = DL.isInfixOf b (TL.unpack $ decodeUtf8 a)

-- | Queries the HTML using a CSS selector, and all matched elements must contain
-- the given string.
htmlAllContain :: HasCallStack => Query -> String -> YesodExample site ()
htmlAllContain query search = do
  matches <- htmlQuery query
  case matches of
    [] -> failure $ "Nothing matched css query: " <> query
    _ -> liftIO $ HUnit.assertBool ("Not all "++T.unpack query++" contain "++search) $
          DL.all (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches)

-- | Queries the HTML using a CSS selector, and passes if any matched
-- element contains the given string.
--
-- Since 0.3.5
htmlAnyContain :: HasCallStack => Query -> String -> YesodExample site ()
htmlAnyContain query search = do
  matches <- htmlQuery query
  case matches of
    [] -> failure $ "Nothing matched css query: " <> query
    _ -> liftIO $ HUnit.assertBool ("None of "++T.unpack query++" contain "++search) $
          DL.any (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches)

-- | Queries the HTML using a CSS selector, and fails if any matched
-- element contains the given string (in other words, it is the logical
-- inverse of htmlAnyContains).
--
-- Since 1.2.2
htmlNoneContain :: HasCallStack => Query -> String -> YesodExample site ()
htmlNoneContain query search = do
  matches <- htmlQuery query
  case DL.filter (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches) of
    [] -> return ()
    found -> failure $ "Found " <> T.pack (show $ length found) <>
                " instances of " <> T.pack search <> " in " <> query <> " elements"

-- | Performs a CSS query on the last response and asserts the matched elements
-- are as many as expected.
htmlCount :: HasCallStack => Query -> Int -> YesodExample site ()
htmlCount query count = do
  matches <- fmap DL.length $ htmlQuery query
  liftIO $ flip HUnit.assertBool (matches == count)
    ("Expected "++(show count)++" elements to match "++T.unpack query++", found "++(show matches))

-- | Outputs the last response body to stderr (So it doesn't get captured by HSpec)
printBody :: YesodExample site ()
printBody = withResponse $ \ SResponse { simpleBody = b } ->
  liftIO $ BSL8.hPutStrLn stderr b

-- | Performs a CSS query and print the matches to stderr.
printMatches :: Query -> YesodExample site ()
printMatches query = do
  matches <- htmlQuery query
  liftIO $ hPutStrLn stderr $ show matches

-- | Add a parameter with the given name and value to the request body.
addPostParam :: T.Text -> T.Text -> RequestBuilder site ()
addPostParam name value =
  ST.modify $ \rbd -> rbd { rbdPostData = (addPostData (rbdPostData rbd)) }
  where addPostData (BinaryPostData _) = error "Trying to add post param to binary content."
        addPostData (MultipleItemsPostData posts) =
          MultipleItemsPostData $ ReqKvPart name value : posts

-- | Add a parameter with the given name and value to the query string.
addGetParam :: T.Text -> T.Text -> RequestBuilder site ()
addGetParam name value = ST.modify $ \rbd -> rbd
    { rbdGets = (TE.encodeUtf8 name, Just $ TE.encodeUtf8 value)
              : rbdGets rbd
    }

-- | Add a file to be posted with the current request.
--
-- Adding a file will automatically change your request content-type to be multipart/form-data.
--
-- ==== __Examples__
--
-- > request $ do
-- >   addFile "profile_picture" "static/img/picture.png" "img/png"
addFile :: T.Text -- ^ The parameter name for the file.
        -> FilePath -- ^ The path to the file.
        -> T.Text -- ^ The MIME type of the file, e.g. "image/png".
        -> RequestBuilder site ()
addFile name path mimetype = do
  contents <- liftIO $ BSL8.readFile path
  ST.modify $ \rbd -> rbd { rbdPostData = (addPostData (rbdPostData rbd) contents) }
    where addPostData (BinaryPostData _) _ = error "Trying to add file after setting binary content."
          addPostData (MultipleItemsPostData posts) contents =
            MultipleItemsPostData $ ReqFilePart name path contents mimetype : posts

-- This looks up the name of a field based on the contents of the label pointing to it.
nameFromLabel :: T.Text -> RequestBuilder site T.Text
nameFromLabel label = do
  mres <- fmap rbdResponse ST.get
  res <-
    case mres of
      Nothing -> failure "nameFromLabel: No response available"
      Just res -> return res
  let
    body = simpleBody res
    mlabel = parseHTML body
                $// C.element "label"
                >=> contentContains label
    mfor = mlabel >>= attribute "for"

    contentContains x c
        | x `T.isInfixOf` T.concat (c $// content) = [c]
        | otherwise = []

  case mfor of
    for:[] -> do
      let mname = parseHTML body
                    $// attributeIs "id" for
                    >=> attribute "name"
      case mname of
        "":_ -> failure $ T.concat
            [ "Label "
            , label
            , " resolved to id "
            , for
            , " which was not found. "
            ]
        name:_ -> return name
        [] -> failure $ "No input with id " <> for
    [] ->
      case filter (/= "") $ mlabel >>= (child >=> C.element "input" >=> attribute "name") of
        [] -> failure $ "No label contained: " <> label
        name:_ -> return name
    _ -> failure $ "More than one label contained " <> label

(<>) :: T.Text -> T.Text -> T.Text
(<>) = T.append

-- How does this work for the alternate <label><input></label> syntax?

-- | Finds the @\<label>@ with the given value, finds its corresponding @\<input>@, then adds a parameter
-- for that input to the request body.
--
-- ==== __Examples__
--
-- Given this HTML, we want to submit @f1=Michael@ to the server:
--
-- > <form method="POST">
-- >   <label for="user">Username</label>
-- >   <input id="user" name="f1" />
-- > </form>
--
-- You can set this parameter like so:
--
-- > request $ do
-- >   byLabel "Username" "Michael"
--
-- This function also supports the implicit label syntax, in which
-- the @\<input>@ is nested inside the @\<label>@ rather than specified with @for@:
--
-- > <form method="POST">
-- >   <label>Username <input name="f1"> </label>
-- > </form>
byLabel :: T.Text -- ^ The text contained in the @\<label>@.
        -> T.Text -- ^ The value to set the parameter to.
        -> RequestBuilder site ()
byLabel label value = do
  name <- nameFromLabel label
  addPostParam name value

-- | Finds the @\<label>@ with the given value, finds its corresponding @\<input>@, then adds a file for that input to the request body.
--
-- ==== __Examples__
--
-- Given this HTML, we want to submit a file with the parameter name @f1@ to the server:
--
-- > <form method="POST">
-- >   <label for="imageInput">Please submit an image</label>
-- >   <input id="imageInput" type="file" name="f1" accept="image/*">
-- > </form>
--
-- You can set this parameter like so:
--
-- > request $ do
-- >   fileByLabel "Please submit an image" "static/img/picture.png" "img/png"
--
-- This function also supports the implicit label syntax, in which
-- the @\<input>@ is nested inside the @\<label>@ rather than specified with @for@:
--
-- > <form method="POST">
-- >   <label>Please submit an image <input type="file" name="f1"> </label>
-- > </form>
fileByLabel :: T.Text -- ^ The text contained in the @\<label>@.
            -> FilePath -- ^ The path to the file.
            -> T.Text -- ^ The MIME type of the file, e.g. "image/png".
            -> RequestBuilder site ()
fileByLabel label path mime = do
  name <- nameFromLabel label
  addFile name path mime

-- | Lookups the hidden input named "_token" and adds its value to the params.
-- Receives a CSS selector that should resolve to the form element containing the token.
--
-- ==== __Examples__
--
-- > request $ do
-- >   addToken_ "#formID"
addToken_ :: Query -> RequestBuilder site ()
addToken_ scope = do
  matches <- htmlQuery' rbdResponse ["Tried to get CSRF token with addToken'"] $ scope <> " input[name=_token][type=hidden][value]"
  case matches of
    [] -> failure $ "No CSRF token found in the current page"
    element:[] -> addPostParam "_token" $ head $ attribute "value" $ parseHTML element
    _ -> failure $ "More than one CSRF token found in the page"

-- | For responses that display a single form, just lookup the only CSRF token available.
--
-- ==== __Examples__
--
-- > request $ do
-- >   addToken
addToken :: RequestBuilder site ()
addToken = addToken_ ""

-- | Calls 'addTokenFromCookieNamedToHeaderNamed' with the 'defaultCsrfCookieName' and 'defaultCsrfHeaderName'.
--
-- Use this function if you're using the CSRF middleware from "Yesod.Core" and haven't customized the cookie or header name.
--
-- ==== __Examples__
--
-- > request $ do
-- >   addTokenFromCookie
--
-- Since 1.4.3.2
addTokenFromCookie :: RequestBuilder site ()
addTokenFromCookie = addTokenFromCookieNamedToHeaderNamed defaultCsrfCookieName defaultCsrfHeaderName

-- | Looks up the CSRF token stored in the cookie with the given name and adds it to the request headers. An error is thrown if the cookie can't be found.
--
-- Use this function if you're using the CSRF middleware from "Yesod.Core" and have customized the cookie or header name.
--
-- See "Yesod.Core.Handler" for details on this approach to CSRF protection.
--
-- ==== __Examples__
--
-- > import Data.CaseInsensitive (CI)
-- > request $ do
-- >   addTokenFromCookieNamedToHeaderNamed "cookieName" (CI "headerName")
--
-- Since 1.4.3.2
addTokenFromCookieNamedToHeaderNamed :: ByteString -- ^ The name of the cookie
                                     -> CI ByteString -- ^ The name of the header
                                     -> RequestBuilder site ()
addTokenFromCookieNamedToHeaderNamed cookieName headerName = do
  cookies <- getRequestCookies
  case M.lookup cookieName cookies of
        Just csrfCookie -> addRequestHeader (headerName, Cookie.setCookieValue csrfCookie)
        Nothing -> failure $ T.concat
          [ "addTokenFromCookieNamedToHeaderNamed failed to lookup CSRF cookie with name: "
          , T.pack $ show cookieName
          , ". Cookies were: "
          , T.pack $ show cookies
          ]

-- | Returns the 'Cookies' from the most recent request. If a request hasn't been made, an error is raised.
--
-- ==== __Examples__
--
-- > request $ do
-- >   cookies <- getRequestCookies
-- >   liftIO $ putStrLn $ "Cookies are: " ++ show cookies
--
-- Since 1.4.3.2
getRequestCookies :: RequestBuilder site Cookies
getRequestCookies = do
  requestBuilderData <- ST.get
  headers <- case simpleHeaders Control.Applicative.<$> rbdResponse requestBuilderData of
                  Just h -> return h
                  Nothing -> failure "getRequestCookies: No request has been made yet; the cookies can't be looked up."

  return $ M.fromList $ map (\c -> (Cookie.setCookieName c, c)) (parseSetCookies headers)


-- | Perform a POST request to @url@.
--
-- ==== __Examples__
--
-- > post HomeR
post :: (Yesod site, RedirectUrl site url)
     => url
     -> YesodExample site ()
post url = request $ do
  setMethod "POST"
  setUrl url

-- | Perform a POST request to @url@ with the given body.
--
-- ==== __Examples__
--
-- > postBody HomeR "foobar"
--
-- > import Data.Aeson
-- > postBody HomeR (encode $ object ["age" .= (1 :: Integer)])
postBody :: (Yesod site, RedirectUrl site url)
         => url
         -> BSL8.ByteString
         -> YesodExample site ()
postBody url body = request $ do
  setMethod "POST"
  setUrl url
  setRequestBody body

-- | Perform a GET request to @url@.
--
-- ==== __Examples__
--
-- > get HomeR
--
-- > get ("http://google.com" :: Text)
get :: (Yesod site, RedirectUrl site url)
    => url
    -> YesodExample site ()
get url = request $ do
    setMethod "GET"
    setUrl url

-- | Follow a redirect, if the last response was a redirect.
-- (We consider a request a redirect if the status is
-- 301, 302, 303, 307 or 308, and the Location header is set.)
--
-- ==== __Examples__
--
-- > get HomeR
-- > followRedirect
followRedirect :: Yesod site
               =>  YesodExample site (Either T.Text T.Text) -- ^ 'Left' with an error message if not a redirect, 'Right' with the redirected URL if it was
followRedirect = do
  mr <- getResponse
  case mr of
   Nothing ->  return $ Left "followRedirect called, but there was no previous response, so no redirect to follow"
   Just r -> do
     if not ((H.statusCode $ simpleStatus r) `elem` [301, 302, 303, 307, 308])
       then return $ Left "followRedirect called, but previous request was not a redirect"
       else do
         case lookup "Location" (simpleHeaders r) of
          Nothing -> return $ Left "followRedirect called, but no location header set"
          Just h -> let url = TE.decodeUtf8 h in
                     get url  >> return (Right url)

-- | Parse the Location header of the last response.
--
-- ==== __Examples__
--
-- > post ResourcesR
-- > (Right (ResourceR resourceId)) <- getLocation
--
-- @since 1.5.4
getLocation :: ParseRoute site => YesodExample site (Either T.Text (Route site))
getLocation = do
  mr <- getResponse
  case mr of
    Nothing -> return $ Left "getLocation called, but there was no previous response, so no Location header"
    Just r -> case lookup "Location" (simpleHeaders r) of
      Nothing -> return $ Left "getLocation called, but the previous response has no Location header"
      Just h -> case parseRoute $ decodePath h of
        Nothing -> return $ Left "getLocation called, but couldn’t parse it into a route"
        Just l -> return $ Right l
  where decodePath b = let (x, y) = BS8.break (=='?') b
                       in (H.decodePathSegments x, unJust <$> H.parseQueryText y)
        unJust (a, Just b) = (a, b)
        unJust (a, Nothing) = (a, Data.Monoid.mempty)

-- | Sets the HTTP method used by the request.
--
-- ==== __Examples__
--
-- > request $ do
-- >   setMethod "POST"
--
-- > import Network.HTTP.Types.Method
-- > request $ do
-- >   setMethod methodPut
setMethod :: H.Method -> RequestBuilder site ()
setMethod m = ST.modify $ \rbd -> rbd { rbdMethod = m }

-- | Sets the URL used by the request.
--
-- ==== __Examples__
--
-- > request $ do
-- >   setUrl HomeR
--
-- > request $ do
-- >   setUrl ("http://google.com/" :: Text)
setUrl :: (Yesod site, RedirectUrl site url)
       => url
       -> RequestBuilder site ()
setUrl url' = do
    site <- fmap rbdSite ST.get
    eurl <- Yesod.Core.Unsafe.runFakeHandler
        M.empty
        (const $ error "Yesod.Test: No logger available")
        site
        (toTextUrl url')
    url <- either (error . show) return eurl
    let (urlPath, urlQuery) = T.break (== '?') url
    ST.modify $ \rbd -> rbd
        { rbdPath =
            case DL.filter (/="") $ H.decodePathSegments $ TE.encodeUtf8 urlPath of
                ("http:":_:rest) -> rest
                ("https:":_:rest) -> rest
                x -> x
        , rbdGets = rbdGets rbd ++ H.parseQuery (TE.encodeUtf8 urlQuery)
        }


-- | Click on a link defined by a CSS query
--
-- ==== __ Examples__
--
-- > get "/foobar"
-- > clickOn "a#idofthelink"
--
-- @since 1.5.7 
clickOn :: Yesod site => Query -> YesodExample site ()
clickOn query = do
  withResponse' yedResponse ["Tried to invoke clickOn in order to read HTML of a previous response."] $ \ res ->
    case findAttributeBySelector (simpleBody res) query "href" of
      Left err -> failure $ query <> " did not parse: " <> T.pack (show err)
      Right [[match]] -> get match
      Right matches -> failure $ "Expected exactly one match for clickOn: got " <> T.pack (show matches)



-- | Simple way to set HTTP request body
--
-- ==== __ Examples__
--
-- > request $ do
-- >   setRequestBody "foobar"
--
-- > import Data.Aeson
-- > request $ do
-- >   setRequestBody $ encode $ object ["age" .= (1 :: Integer)]
setRequestBody :: BSL8.ByteString -> RequestBuilder site ()
setRequestBody body = ST.modify $ \rbd -> rbd { rbdPostData = BinaryPostData body }

-- | Adds the given header to the request; see "Network.HTTP.Types.Header" for creating 'Header's.
--
-- ==== __Examples__
--
-- > import Network.HTTP.Types.Header
-- > request $ do
-- >   addRequestHeader (hUserAgent, "Chrome/41.0.2228.0")
addRequestHeader :: H.Header -> RequestBuilder site ()
addRequestHeader header = ST.modify $ \rbd -> rbd
    { rbdHeaders = header : rbdHeaders rbd
    }

-- | The general interface for performing requests. 'request' takes a 'RequestBuilder',
-- constructs a request, and executes it.
--
-- The 'RequestBuilder' allows you to build up attributes of the request, like the
-- headers, parameters, and URL of the request.
--
-- ==== __Examples__
--
-- > request $ do
-- >   addToken
-- >   byLabel "First Name" "Felipe"
-- >   setMethod "PUT"
-- >   setUrl NameR
request :: RequestBuilder site ()
        -> YesodExample site ()
request reqBuilder = do
    YesodExampleData app site oldCookies mRes <- ST.get

    RequestBuilderData {..} <- liftIO $ ST.execStateT reqBuilder RequestBuilderData
      { rbdPostData = MultipleItemsPostData []
      , rbdResponse = mRes
      , rbdMethod = "GET"
      , rbdSite = site
      , rbdPath = []
      , rbdGets = []
      , rbdHeaders = []
      }
    let path
            | null rbdPath = "/"
            | otherwise = TE.decodeUtf8 $ Builder.toByteString $ H.encodePathSegments rbdPath

    -- expire cookies and filter them for the current path. TODO: support max age
    currentUtc <- liftIO getCurrentTime
    let cookies = M.filter (checkCookieTime currentUtc) oldCookies
        cookiesForPath = M.filter (checkCookiePath path) cookies

    let req = case rbdPostData of
          MultipleItemsPostData x ->
            if DL.any isFile x
            then (multipart x)
            else singlepart
          BinaryPostData _ -> singlepart
          where singlepart = makeSinglepart cookiesForPath rbdPostData rbdMethod rbdHeaders path rbdGets
                multipart x = makeMultipart cookiesForPath x rbdMethod rbdHeaders path rbdGets
    -- let maker = case rbdPostData of
    --       MultipleItemsPostData x ->
    --         if DL.any isFile x
    --         then makeMultipart
    --         else makeSinglepart
    --       BinaryPostData _ -> makeSinglepart
    -- let req = maker cookiesForPath rbdPostData rbdMethod rbdHeaders path rbdGets
    response <- liftIO $ runSession (srequest req
        { simpleRequest = (simpleRequest req)
            { httpVersion = H.http11
            }
        }) app
    let newCookies = parseSetCookies $ simpleHeaders response
        cookies' = M.fromList [(Cookie.setCookieName c, c) | c <- newCookies] `M.union` cookies
    ST.put $ YesodExampleData app site cookies' (Just response)
  where
    isFile (ReqFilePart _ _ _ _) = True
    isFile _ = False

    checkCookieTime t c = case Cookie.setCookieExpires c of
                              Nothing -> True
                              Just t' -> t < t'
    checkCookiePath url c =
      case Cookie.setCookiePath c of
        Nothing -> True
        Just x  -> x `BS8.isPrefixOf` TE.encodeUtf8 url

    -- For building the multi-part requests
    boundary :: String
    boundary = "*******noneedtomakethisrandom"
    separator = BS8.concat ["--", BS8.pack boundary, "\r\n"]
    makeMultipart :: M.Map a0 Cookie.SetCookie
                  -> [RequestPart]
                  -> H.Method
                  -> [H.Header]
                  -> T.Text
                  -> H.Query
                  -> SRequest
    makeMultipart cookies parts method extraHeaders urlPath urlQuery =
      SRequest simpleRequest' (simpleRequestBody' parts)
      where simpleRequestBody' x =
              BSL8.fromChunks [multiPartBody x]
            simpleRequest' = mkRequest
                             [ ("Cookie", cookieValue)
                             , ("Content-Type", contentTypeValue)]
                             method extraHeaders urlPath urlQuery
            cookieValue = Builder.toByteString $ Cookie.renderCookies cookiePairs
            cookiePairs = [ (Cookie.setCookieName c, Cookie.setCookieValue c)
                          | c <- map snd $ M.toList cookies ]
            contentTypeValue = BS8.pack $ "multipart/form-data; boundary=" ++ boundary
    multiPartBody parts =
      BS8.concat $ separator : [BS8.concat [multipartPart p, separator] | p <- parts]
    multipartPart (ReqKvPart k v) = BS8.concat
      [ "Content-Disposition: form-data; "
      , "name=\"", TE.encodeUtf8 k, "\"\r\n\r\n"
      , TE.encodeUtf8 v, "\r\n"]
    multipartPart (ReqFilePart k v bytes mime) = BS8.concat
      [ "Content-Disposition: form-data; "
      , "name=\"", TE.encodeUtf8 k, "\"; "
      , "filename=\"", BS8.pack v, "\"\r\n"
      , "Content-Type: ", TE.encodeUtf8 mime, "\r\n\r\n"
      , BS8.concat $ BSL8.toChunks bytes, "\r\n"]

    -- For building the regular non-multipart requests
    makeSinglepart :: M.Map a0 Cookie.SetCookie
                   -> RBDPostData
                   -> H.Method
                   -> [H.Header]
                   -> T.Text
                   -> H.Query
                   -> SRequest
    makeSinglepart cookies rbdPostData method extraHeaders urlPath urlQuery =
      SRequest simpleRequest' (simpleRequestBody' rbdPostData)
      where
        simpleRequest' = (mkRequest
                          ([ ("Cookie", cookieValue) ] ++ headersForPostData rbdPostData)
                          method extraHeaders urlPath urlQuery)
        simpleRequestBody' (MultipleItemsPostData x) =
          BSL8.fromChunks $ return $ TE.encodeUtf8 $ T.intercalate "&"
          $ map singlepartPart x
        simpleRequestBody' (BinaryPostData x) = x
        cookieValue = Builder.toByteString $ Cookie.renderCookies cookiePairs
        cookiePairs = [ (Cookie.setCookieName c, Cookie.setCookieValue c)
                      | c <- map snd $ M.toList cookies ]
        singlepartPart (ReqFilePart _ _ _ _) = ""
        singlepartPart (ReqKvPart k v) = T.concat [k,"=",v]

        -- If the request appears to be submitting a form (has key-value pairs) give it the form-urlencoded Content-Type.
        -- The previous behavior was to always use the form-urlencoded Content-Type https://github.com/yesodweb/yesod/issues/1063
        headersForPostData (MultipleItemsPostData []) = []
        headersForPostData (MultipleItemsPostData _ ) = [("Content-Type", "application/x-www-form-urlencoded")]
        headersForPostData (BinaryPostData _ ) = []


    -- General request making
    mkRequest headers method extraHeaders urlPath urlQuery = defaultRequest
      { requestMethod = method
      , remoteHost = Sock.SockAddrInet 1 2
      , requestHeaders = headers ++ extraHeaders
      , rawPathInfo = TE.encodeUtf8 urlPath
      , pathInfo = H.decodePathSegments $ TE.encodeUtf8 urlPath
      , rawQueryString = H.renderQuery False urlQuery
      , queryString = urlQuery
      }


parseSetCookies :: [H.Header] -> [Cookie.SetCookie]
parseSetCookies headers = map (Cookie.parseSetCookie . snd) $ DL.filter (("Set-Cookie"==) . fst) $ headers

-- Yes, just a shortcut
failure :: (MonadIO a) => T.Text -> a b
failure reason = (liftIO $ HUnit.assertFailure $ T.unpack reason) >> error ""

type TestApp site = (site, Middleware)
testApp :: site -> Middleware -> TestApp site
testApp site middleware = (site, middleware)
type YSpec site = Hspec.SpecWith (TestApp site)

instance YesodDispatch site => Hspec.Example (ST.StateT (YesodExampleData site) IO a) where
    type Arg (ST.StateT (YesodExampleData site) IO a) = TestApp site

    evaluateExample example params action =
        Hspec.evaluateExample
            (action $ \(site, middleware) -> do
                app <- toWaiAppPlain site
                _ <- ST.evalStateT example YesodExampleData
                    { yedApp = middleware app
                    , yedSite = site
                    , yedCookies = M.empty
                    , yedResponse = Nothing
                    }
                return ())
            params
            ($ ())
