module Main (main) where

import Control.Monad (filterM, unless)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import System.Directory (doesDirectoryExist, doesPathExist, listDirectory)
import System.FilePath (normalise, takeDirectory, (</>))

main :: IO ()
main = do
  sourceFiles <- hsFiles "src"
  protoViolations <- concat <$> traverse protoImportViolations sourceFiles
  docViolations <- documentationViolations
  let violations = protoViolations <> docViolations
  unless (null violations) do
    error ("style violations:\n" <> unlines violations)

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

documentationViolations :: IO [String]
documentationViolations = do
  documentFiles <- mdFiles "documents"
  planFiles <- mdFiles "DEVELOPMENT_PLAN"
  let governedRootFiles = ["README.md", "AGENTS.md", "CLAUDE.md", "DEVELOPMENT_PLAN/README.md"]
      planMetadataFiles = filter (/= "DEVELOPMENT_PLAN/README.md") planFiles
      phaseFiles = filter (isPrefixOf "DEVELOPMENT_PLAN/phase-") planFiles
  concat
    <$> sequence
      [ concat <$> traverse governedDocumentMetadataViolations documentFiles,
        concat <$> traverse governedRootMetadataViolations governedRootFiles,
        concat <$> traverse governedDocumentMetadataViolations planMetadataFiles,
        concat <$> traverse phaseStructureViolations phaseFiles,
        broadDocumentHeadingViolations,
        rootReadmeLinkViolations,
        concat <$> traverse markdownLinkViolations (documentFiles <> planFiles <> ["README.md", "AGENTS.md", "CLAUDE.md"])
      ]

mdFiles :: FilePath -> IO [FilePath]
mdFiles root = do
  allFiles <- allFilesUnder root
  pure [path | path <- allFiles, ".md" `isSuffixOf` path]

allFilesUnder :: FilePath -> IO [FilePath]
allFilesUnder root = do
  entries <- listDirectory root
  fmap concat $
    traverse
      ( \entry -> do
          let path = root </> entry
          isDirectory <- doesDirectoryExist path
          if isDirectory
            then allFilesUnder path
            else pure [path]
      )
      entries

governedDocumentMetadataViolations :: FilePath -> IO [String]
governedDocumentMetadataViolations path = do
  content <- readFile path
  pure (metadataViolations path "**Referenced by**:" content)

governedRootMetadataViolations :: FilePath -> IO [String]
governedRootMetadataViolations path = do
  content <- readFile path
  pure (metadataViolations path "**Canonical homes**:" content)

metadataViolations :: FilePath -> String -> String -> [String]
metadataViolations path linkLine content =
  let fileLines = lines content
      hasLine n predicate = maybe False predicate (lineAt n fileLines)
      hasPurpose = any (isPrefixOf "> **Purpose**:") (take 8 fileLines)
   in concat
        [ [path <> ":1: first line must be a top-level title" | not (hasLine 1 (isPrefixOf "# "))],
          [path <> ":3: missing `**Status**:` metadata line" | not (hasLine 3 (isPrefixOf "**Status**:"))],
          [path <> ":4: missing `**Supersedes**:` metadata line" | not (hasLine 4 (isPrefixOf "**Supersedes**:"))],
          [path <> ":5: missing `" <> linkLine <> "` metadata line" | not (hasLine 5 (isPrefixOf linkLine))],
          [path <> ":7: missing purpose blockquote in metadata block" | not hasPurpose]
        ]

lineAt :: Int -> [a] -> Maybe a
lineAt n values
  | n <= 0 = Nothing
  | otherwise = case drop (n - 1) values of
      value : _ -> Just value
      [] -> Nothing

phaseStructureViolations :: FilePath -> IO [String]
phaseStructureViolations path = do
  content <- readFile path
  let fileLines = lines content
      required =
        [ "## Phase Status",
          "## Phase Objective",
          "## Sprints",
          "## Documentation Requirements"
        ]
  pure [path <> ": missing `" <> heading <> "` section" | heading <- required, heading `notElem` fileLines]

broadDocumentHeadingViolations :: IO [String]
broadDocumentHeadingViolations =
  concat
    <$> traverse
      requiredHeadingViolations
      [ ("documents/documentation_standards.md", ["## TL;DR", "## Validation"]),
        ("documents/development/testing_strategy.md", ["## TL;DR"]),
        ("documents/engineering/cabal_layout.md", ["## TL;DR", "## Current Status"]),
        ("documents/engineering/cluster_topology.md", ["## TL;DR", "## Current Status"]),
        ("documents/engineering/hostbootstrap_integration.md", ["## TL;DR", "## Current Status"]),
        ("documents/reference/cli_surface.md", ["## TL;DR", "## Current Status"])
      ]

requiredHeadingViolations :: (FilePath, [String]) -> IO [String]
requiredHeadingViolations (path, headings) = do
  content <- readFile path
  let fileLines = lines content
  pure [path <> ": missing `" <> heading <> "` heading" | heading <- headings, heading `notElem` fileLines]

rootReadmeLinkViolations :: IO [String]
rootReadmeLinkViolations = do
  content <- readFile "README.md"
  pure $
    concat
      [ ["README.md: missing link to `documents/README.md`" | "(documents/README.md)" `notElemIn` content],
        ["README.md: missing link to `DEVELOPMENT_PLAN/README.md`" | "(DEVELOPMENT_PLAN/README.md)" `notElemIn` content]
      ]

notElemIn :: String -> String -> Bool
notElemIn needle haystack = not (needle `isInfixOf` haystack)

markdownLinkViolations :: FilePath -> IO [String]
markdownLinkViolations path = do
  content <- readFile path
  let links = markdownLinksOutsideCode content
  missing <-
    filterM
      ( \(_lineNumber, target) -> do
          let resolved = resolveMarkdownTarget path target
          case resolved of
            Nothing -> pure False
            Just candidate -> not <$> doesPathExist candidate
      )
      links
  pure [path <> ":" <> show lineNumber <> ": unresolved Markdown link target `" <> target <> "`" | (lineNumber, target) <- missing]

markdownLinksOutsideCode :: String -> [(Int, String)]
markdownLinksOutsideCode content = go False 1 (lines content)
  where
    go _ _ [] = []
    go inFence lineNumber (line : rest)
      | "```" `isPrefixOf` dropWhile isSpace line = go (not inFence) (lineNumber + 1) rest
      | inFence = go inFence (lineNumber + 1) rest
      | otherwise = [(lineNumber, target) | target <- extractMarkdownLinks line] <> go inFence (lineNumber + 1) rest

extractMarkdownLinks :: String -> [String]
extractMarkdownLinks "" = []
extractMarkdownLinks input =
  case dropWhile (/= '[') input of
    "" -> []
    '[' : rest ->
      case break (== ']') rest of
        (_, ']' : '(' : afterOpen) ->
          let (target, afterTarget) = break (== ')') afterOpen
           in target : extractMarkdownLinks (drop 1 afterTarget)
        (_, remaining) -> extractMarkdownLinks remaining
    _ -> []

resolveMarkdownTarget :: FilePath -> String -> Maybe FilePath
resolveMarkdownTarget sourcePath rawTarget
  | null target = Nothing
  | "#" `isPrefixOf` target = Nothing
  | "http://" `isPrefixOf` target = Nothing
  | "https://" `isPrefixOf` target = Nothing
  | "mailto:" `isPrefixOf` target = Nothing
  | otherwise =
      let withoutAnchor = takeWhile (/= '#') target
       in if null withoutAnchor
            then Nothing
            else Just (normalise (takeDirectory sourcePath </> withoutAnchor))
  where
    target = cleanMarkdownTarget rawTarget

cleanMarkdownTarget :: String -> String
cleanMarkdownTarget raw =
  case dropWhile isSpace raw of
    '<' : rest -> takeWhile (/= '>') rest
    stripped -> takeWhile (not . isSpace) stripped
