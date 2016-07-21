{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Sos.Template
  ( RawTemplate
  , Template
  , parseTemplate
  , instantiateTemplate
  ) where

import Sos.Exception
import Sos.Job       (ShellCommand)
import Sos.Utils

import Control.Applicative
import Control.Monad.Except
import Data.ByteString      (ByteString)
import Data.Monoid
import Text.Parsec

import qualified Data.Text.Encoding     as Text
import qualified Data.Text.Lazy         as LText
import qualified Data.Text.Lazy.Builder as LText


-- | A 'RawTemplate' represents a shell command, possibly containing capture
-- groups, e.g. "ghc \0"
type RawTemplate = ByteString

-- A 'Template' is a parsed 'RawTemplate' that replaces all capture groups with
-- Lefts.
--
-- For example, the raw template
--
--    "gcc -c \1.c -o \1.c"
--
-- will become
--
--    [Right "gcc -c ", Left 1, Right ".c -o ", Left 1, Right ".c"]
--
type Template = [Either Int ByteString]


parseTemplate :: MonadError SosException m => RawTemplate -> m Template
parseTemplate template =
  case runParser parser () "" template of
    Left err -> throwError (SosCommandParseException template err)
    Right x  -> return x
 where
  parser :: Parsec ByteString () Template
  parser = some (capturePart <|||> textPart)
   where
    textPart :: Parsec ByteString () ByteString
    textPart = packBS <$> some (satisfy (/= '\\'))

    capturePart :: Parsec ByteString () Int
    capturePart = read <$> (char '\\' *> some digit)

-- Instantiate a template with a list of captured variables, per their indices.
--
-- For example,
--
--    instantiateTemplate ["ONE", "TWO"] [Right "foo", Left 0, Right "bar", Left 1] == "fooONEbarTWO"
--
instantiateTemplate
  :: forall m. MonadError SosException m
  => [ByteString]
  -> Template
  -> m ShellCommand
instantiateTemplate vars0 template0 = go 0 vars0 template0
 where
  go :: Int -> [ByteString] -> Template -> m ShellCommand
  go _ [] template =
    case flattenTemplate template of
      Left err -> throwError (SosCommandApplyException template0 vars0 err)
      Right x  -> return x
  go n (t:ts) template = go (n+1) ts (map f template)
   where
    f :: Either Int ByteString -> Either Int ByteString
    f (Left n')
        | n == n'   = Right t
        | otherwise = Left n'
    f x = x

-- Attempt to flatten a list of Rights to a single string.
flattenTemplate :: Template -> Either String ShellCommand
flattenTemplate = go mempty
 where
  go :: LText.Builder -> Template -> Either String ShellCommand
  go !acc [] = Right (LText.unpack (LText.toLazyText acc))
  go !acc (Right x : xs) = go (acc <> LText.fromText (Text.decodeUtf8 x)) xs
  go _   (Left n : _) = Left ("uninstantiated template variable \\" <> show n)