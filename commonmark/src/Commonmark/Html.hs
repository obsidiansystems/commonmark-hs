{-# LANGUAGE CPP                        #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE UndecidableInstances       #-}
module Commonmark.Html
  ( Html(..)
  , ElementType(..)
  , Attribute
  , htmlInline
  , htmlBlock
  , htmlText
  , htmlRaw
  , addAttribute
  , renderHtml
  , escapeURI
  , escapeHtml
  )
where

import           Commonmark.Types
import           Commonmark.Entity (lookupEntity)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Builder (Builder, fromText, toLazyText,
                                         singleton)
import           Data.Text.Encoding   (encodeUtf8)
import qualified Data.ByteString.Char8 as B
import           Text.Printf          (printf)
import           Data.Char            (ord, isAlphaNum, isAscii, isSpace)
import           Data.Maybe           (fromMaybe)
#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif

data ElementType =
    InlineElement
  | BlockElement

data Html a =
    HtmlElement !ElementType {-# UNPACK #-} !Text [Attribute] (Maybe (Html a))
  | HtmlText {-# UNPACK #-} !Text
  | HtmlRaw {-# UNPACK #-} !Text
  | HtmlNull
  | HtmlConcat !(Html a) !(Html a)

instance Show (Html a) where
  show = TL.unpack . renderHtml

instance Semigroup (Html a) where
  x <> HtmlNull                = x
  HtmlNull <> x                = x
  HtmlText t1 <> HtmlText t2   = HtmlText (t1 <> t2)
  HtmlRaw t1 <> HtmlRaw t2     = HtmlRaw (t1 <> t2)
  x <> y                       = HtmlConcat x y

instance Monoid (Html a) where
  mempty = HtmlNull
  mappend = (<>)

instance HasAttributes (Html a) where
  addAttributes attrs x = foldr addAttribute x attrs

instance ToPlainText (Html a) where
  toPlainText h =
    case h of
      HtmlElement InlineElement "span" attr (Just x)
        -> case lookup "data-emoji" attr of
              Just alias -> ":" <> alias <> ":"
              Nothing    -> toPlainText x
      HtmlElement _ _ _ (Just x) -> toPlainText x
      HtmlElement _ _ attrs Nothing
                                 -> fromMaybe mempty $ lookup "alt" attrs
      HtmlText t                 -> t
      HtmlConcat x y             -> toPlainText x <> toPlainText y
      _                          -> mempty


-- This instance mirrors what is expected in the spec tests.
instance Rangeable (Html a) => IsInline (Html a) where
  lineBreak = htmlInline "br" Nothing <> nl
  softBreak = nl
  str t = htmlText t
  entity t = case lookupEntity (T.drop 1 t) of
                   Just t' -> htmlText t'
                   Nothing -> htmlRaw t
  escapedChar c = htmlText (T.singleton c)
  emph ils = htmlInline "em" (Just ils)
  strong ils = htmlInline "strong" (Just ils)
  link target title ils =
    addAttribute ("href", escapeURI target) .
    (if T.null title
        then id
        else addAttribute ("title", title)) $
    htmlInline "a" (Just ils)
  image target title ils =
    addAttribute ("src", escapeURI target) .
    addAttribute ("alt", toPlainText ils) .
    (if T.null title
        then id
        else addAttribute ("title", title)) $
    htmlInline "img" Nothing
  code t = htmlInline "code" (Just (htmlText t))
  rawInline f t
    | f == Format "html" = htmlRaw t
    | otherwise          = mempty

instance IsInline (Html a) => IsBlock (Html a) (Html a) where
  paragraph ils = htmlBlock "p" (Just ils)
  plain ils = ils <> nl
  thematicBreak = htmlBlock "hr" Nothing
  blockQuote bs = htmlBlock "blockquote" $ Just (nl <> bs)
  codeBlock info t =
    htmlBlock "pre" $ Just $
    (if T.null lang
        then id
        else addAttribute ("class", "language-" <> lang)) $
    htmlInline "code" $ Just (htmlText t)
    where lang = T.takeWhile (not . isSpace) info
  heading level ils = htmlBlock h (Just ils)
    where h = case level of
                   1 -> "h1"
                   2 -> "h2"
                   3 -> "h3"
                   4 -> "h4"
                   5 -> "h5"
                   6 -> "h6"
                   _ -> "p"
  rawBlock f t
    | f == Format "html" = htmlRaw t
    | otherwise          = mempty
  referenceLinkDefinition _ _ = mempty
  list (BulletList _) lSpacing items =
    htmlBlock "ul" $ Just (nl <> mconcat (map li items))
   where li x = htmlBlock "li" $
                   Just ((if lSpacing == TightList
                             then mempty
                             else nl) <> x)
  list (OrderedList startnum enumtype _delimtype) lSpacing items =
    (if startnum /= 1
        then addAttribute ("start", T.pack (show startnum))
        else id) .
    (case enumtype of
       Decimal  -> id
       UpperAlpha -> addAttribute ("type", "A")
       LowerAlpha -> addAttribute ("type", "a")
       UpperRoman -> addAttribute ("type", "I")
       LowerRoman -> addAttribute ("type", "i"))
    $ htmlBlock "ol" $
      Just (nl <> mconcat (map li items))
   where li x = htmlBlock "li" $
                   Just ((if lSpacing == TightList
                             then mempty
                             else nl) <> x)

nl :: Html a
nl = htmlRaw "\n"

instance Rangeable (Html ()) where
  ranged _ x = x

instance Rangeable (Html SourceRange) where
  ranged sr x = addAttribute ("data-sourcepos", T.pack (show sr)) x



htmlInline :: Text -> Maybe (Html a) -> Html a
htmlInline tagname mbcontents = HtmlElement InlineElement tagname [] mbcontents

htmlBlock :: Text -> Maybe (Html a) -> Html a
htmlBlock tagname mbcontents = HtmlElement BlockElement tagname [] mbcontents

htmlText :: Text -> Html a
htmlText = HtmlText

htmlRaw :: Text -> Html a
htmlRaw = HtmlRaw

addAttribute :: Attribute -> Html a -> Html a
addAttribute attr (HtmlElement eltType tagname attrs mbcontents) =
  HtmlElement eltType tagname (incorporateAttribute attr attrs) mbcontents
addAttribute attr (HtmlText t)
  = HtmlElement InlineElement "span" [attr] $ Just (HtmlText t)
addAttribute _ elt = elt

incorporateAttribute :: Attribute -> [Attribute] -> [Attribute]
incorporateAttribute (k, v) as =
  case lookup k as of
    Nothing            -> (k, v) : as
    Just v'            -> (if k == "class"
                              then ("class", v <> " " <> v')
                              else (k, v')) :
                          filter (\(x, _) -> x /= k) as

renderHtml :: Html a -> TL.Text
renderHtml = {-# SCC renderHtml #-} toLazyText . toBuilder

toBuilder :: Html a -> Builder
toBuilder (HtmlNull) = mempty
toBuilder (HtmlConcat x y) = toBuilder x <> toBuilder y
toBuilder (HtmlRaw t) = fromText t
toBuilder (HtmlText t) = escapeHtml t
toBuilder (HtmlElement eltType tagname attrs mbcontents) =
  "<" <> fromText tagname <> mconcat (map toAttr attrs) <> filling <> nl'
  where
    toAttr (x,y) = " " <> fromText x <> "=\"" <> escapeHtml y <> "\""
    nl' = case eltType of
           BlockElement -> "\n"
           _            -> mempty
    filling = case mbcontents of
                 Nothing   -> " />"
                 Just cont -> ">" <> toBuilder cont <> "</" <>
                              fromText tagname <> ">"

escapeHtml :: Text -> Builder
escapeHtml t =
  case T.uncons post of
    Just (c, rest) -> fromText pre <> escapeHtmlChar c <> escapeHtml rest
    Nothing        -> fromText pre
 where
  (pre,post)        = T.break needsEscaping t
  needsEscaping '<' = True
  needsEscaping '>' = True
  needsEscaping '&' = True
  needsEscaping '"' = True
  needsEscaping _   = False

escapeHtmlChar :: Char -> Builder
escapeHtmlChar '<' = "&lt;"
escapeHtmlChar '>' = "&gt;"
escapeHtmlChar '&' = "&amp;"
escapeHtmlChar '"' = "&quot;"
escapeHtmlChar c   = singleton c

escapeURI :: Text -> Text
escapeURI = mconcat . map escapeURIChar . B.unpack . encodeUtf8

escapeURIChar :: Char -> Text
escapeURIChar c
  | isEscapable c = T.singleton '%' <> T.pack (printf "%02X" (ord c))
  | otherwise     = T.singleton c
  where isEscapable d = not (isAscii d && isAlphaNum d)
                     && d `notElem` ['%','/','?',':','@','-','.','_','~','&',
                                     '#','!','$','\'','(',')','*','+',',',
                                     ';','=']

