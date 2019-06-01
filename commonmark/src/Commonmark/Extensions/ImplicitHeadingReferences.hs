{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
module Commonmark.Extensions.ImplicitHeadingReferences
  ( implicitHeadingReferencesSpec
  )
where
import Commonmark.Types
import Commonmark.Tokens
import Commonmark.Syntax
import Commonmark.Blocks
import Commonmark.ReferenceMap
import Data.Maybe (fromMaybe)
import Text.Parsec

implicitHeadingReferencesSpec
         :: (Monad m, IsBlock il bl, IsInline il)
         => SyntaxSpec m il bl
implicitHeadingReferencesSpec = mempty
  { syntaxFinalParsers = [addHeadingReferences]
  }

-- Go through the node stack and add implicit references
-- for each header.
addHeadingReferences :: (Monad m, IsBlock il bl, IsInline il)
                    => BlockParser m il bl bl
addHeadingReferences = do
  nodes <- nodeStack <$> getState
  mapM_ (traverse addHeadingRef) nodes
  return mempty

addHeadingRef :: (Monad m, IsBlock il bl, IsInline il)
             => BlockData m il bl -> BlockParser m il bl ()
addHeadingRef bd
  | blockType (blockSpec bd) `elem` ["ATXHeading", "SetextHeading"] = do
      -- update ref map
      let lab = untokenize . removeIndent . mconcat . reverse . blockLines $ bd
      let ident = fromMaybe "" $ lookup "id" $ blockAttributes bd
      updateState $ \s -> s{
        referenceMap = insertReference lab 
          LinkInfo{ linkDestination = "#" <> ident
                  , linkTitle = mempty
                  , linkAttributes = mempty }
          (referenceMap s) }
  | otherwise = return ()
