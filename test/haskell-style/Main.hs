module Main (main) where

import Control.Monad (unless)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

main :: IO ()
main = do
  sourceFiles <- hsFiles "src"
  violations <- concat <$> traverse protoImportViolations sourceFiles
  unless (null violations) do
    error ("direct Daemon.Proto import outside wire/boundary modules:\n" <> unlines violations)

hsFiles :: FilePath -> IO [FilePath]
hsFiles root = do
  entries <- listDirectory root
  fmap concat $
    traverse
      ( \entry -> do
          let path = root </> entry
          isDirectory <- doesDirectoryExist path
          if isDirectory
            then hsFiles path
            else pure [path | ".hs" `isSuffixOf` path]
      )
      entries

protoImportViolations :: FilePath -> IO [String]
protoImportViolations path
  | protoImportAllowed path = pure []
  | otherwise = do
      content <- readFile path
      pure
        [ path <> ":" <> show lineNumber <> ": " <> line
        | (lineNumber, line) <- zip [1 :: Int ..] (lines content),
          "import " `isInfixOf` line,
          "Daemon.Proto" `isInfixOf` line
        ]

protoImportAllowed :: FilePath -> Bool
protoImportAllowed path =
  path == "src/Daemon/Audit.hs"
    || path == "src/Daemon/Consumer.hs"
    || path == "src/Daemon/WorkflowState.hs"
    || any
      (`isPrefixOf` path)
      [ "src/Daemon/Proto/",
        "src/Daemon/Wire/",
        "src/Daemon/Pulsar/Native",
        "src/Daemon/Test/"
      ]
