module Bin.Main where

import Prelude

import App.Env as Env
import ArgParse.Basic (ArgParser)
import ArgParse.Basic as Arg
import Bin.AppM (AppM)
import Bin.AppM as AppM
import Control.Monad.Reader (ask)
import Data.Array as Array
import Data.DateTime.Instant as Instant
import Data.Either (Either(..))
import Data.Foldable (foldMap)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Monoid (guard)
import Data.Monoid.Additive (Additive(..))
import Data.Newtype (alaF, un)
import Data.Number.Format as Number
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Traversable (for, traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Milliseconds(..))
import Effect.Aff as Aff
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Now as Now
import Lib.Foreign.Octokit (Release, ReleaseAsset)
import Lib.Foreign.Octokit as Octokit
import Lib.Foreign.Tmp as Tmp
import Lib.Git (Tag(..))
import Lib.Git as Git
import Lib.GitHub (Repo(..))
import Lib.GitHub as GitHub
import Lib.Nix.Manifest (PursManifest, SpagoManifest, FetchUrl)
import Lib.Nix.Manifest as Nix.Manifest
import Lib.Nix.Prefetch as Nix.Prefetch
import Lib.Nix.System (NixSystem(..))
import Lib.Nix.System as Nix.System
import Lib.Nix.Version (NixVersion(..))
import Lib.Nix.Version as Nix.Version
import Lib.Utils as Utils
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as Process
import Registry.Sha256 as Sha256
import Registry.Version as Version

data Commit = DoCommit | NoCommit

derive instance Eq Commit

-- TODO: Allow specifying one or more specific tools to include (default to all).
-- Make the manifest dir optional (default: use git rev-parse to go to the root,
-- look for a "manifests" directory containing "purs.json" and "spago.json").
--
-- Then, commands mean "verify <tool> using <dir>" or "update <tool>"
data Command
  = Verify FilePath
  | Prefetch FilePath
  | Update FilePath Commit

derive instance Eq Command

parser :: ArgParser Command
parser =
  Arg.choose "command"
    [ Arg.command [ "verify" ]
        "Verify that the generation script can read and write the manifests."
        do
          Verify <$> manifestDir
            <* Arg.flagHelp
    , Arg.command [ "prefetch" ]
        "Run the generation script without modifying files (print output)."
        do
          Prefetch <$> manifestDir
            <* Arg.flagHelp
    , Arg.command [ "update" ]
        "Run the generation script and write files."
        do
          Update
            <$> manifestDir
            <*> updateOptions
            <* Arg.flagHelp
    ] <* Arg.flagHelp
  where
  manifestDir =
    Arg.anyNotFlag "MANIFEST_DIR" "Location of the tooling manifests"

  updateOptions =
    Arg.flag [ "--commit" ]
      "Whether to commit results and open a pull request. Default: false"
      # Arg.boolean
      # Arg.default false
      # map (if _ then DoCommit else NoCommit)

main :: Effect Unit
main = Aff.launchAff_ do
  args <- Array.drop 2 <$> liftEffect Process.argv

  let description = "A generation script for updating PureScript tooling versions."
  mode <- case Arg.parseArgs "generate" description parser args of
    Left error -> do
      Console.log (Arg.printArgError error)
      case error of
        Arg.ArgError _ Arg.ShowHelp -> do
          liftEffect (Process.exit 0)
        _ ->
          liftEffect (Process.exit 1)
    Right command ->
      pure command

  -- Set up the environment...
  tmp <- Tmp.mkTmpDir
  now <- liftEffect Now.now
  let random = Number.toString $ un Milliseconds $ Instant.unInstant now
  let branch = "generate/" <> fromMaybe random (String.stripSuffix (String.Pattern ".0") random)

  case mode of
    Verify dir -> do
      let envFile = Path.concat [ dir, "..", "generate", ".env" ]
      Console.log $ "Loading .env file from " <> envFile
      liftAff $ Env.loadEnvFile envFile
      token <- Env.lookupOptional Env.githubToken
      octokit <- case token of
        Nothing -> Octokit.newOctokit
        Just tok -> Octokit.newAuthOctokit tok
      AppM.runAppM { octokit, manifestDir: dir, gitBranch: branch, tmpDir: tmp } do
        Console.log "Verifying manifests..."
        pursManifest <- readPursManifest
        let pursEntries = alaF Additive foldMap Map.size (Map.values pursManifest)
        Console.log $ "Successfully parsed purs.json with " <> Int.toStringAs Int.decimal pursEntries <> " entries."
        spagoManifest <- readSpagoManifest
        let spagoEntries = Map.size spagoManifest
        Console.log $ "Successfully parsed spago.json with " <> Int.toStringAs Int.decimal spagoEntries <> " entries."

    Prefetch dir -> do
      let envFile = Path.concat [ dir, "..", "generate", ".env" ]
      Console.log $ "Loading .env file from " <> envFile
      liftAff $ Env.loadEnvFile envFile
      token <- Env.lookupOptional Env.githubToken
      octokit <- case token of
        Nothing -> Octokit.newOctokit
        Just tok -> Octokit.newAuthOctokit tok
      AppM.runAppM { octokit, manifestDir: dir, gitBranch: branch, tmpDir: tmp } do
        Console.log "Prefetching new releases..."
        pursManifest <- readPursManifest
        pursUpdates <- fetchPursReleases (Set.unions $ map Map.keys $ Map.values pursManifest)
        if Map.size pursUpdates > 0 then
          Console.log $ "New purs releases: " <> Utils.printJson Nix.Manifest.pursManifestCodec pursUpdates
        else Console.log "No new purs releases."
        spagoUpdates <- fetchSpagoReleases
        if Map.size spagoUpdates > 0 then
          Console.log $ "New spago releases: " <> Utils.printJson Nix.Manifest.spagoManifestCodec spagoUpdates
        else Console.log "No new spago releases."

    Update dir commit -> do
      let envFile = Path.concat [ dir, "..", "generate", ".env" ]
      Console.log $ "Loading .env file from " <> envFile
      liftAff $ Env.loadEnvFile envFile
      octokit <- case commit of
        DoCommit -> do
          token <- Env.lookupRequired Env.githubToken
          Octokit.newAuthOctokit token
        NoCommit -> do
          Env.lookupOptional Env.githubToken >>= case _ of
            Nothing -> Octokit.newOctokit
            Just tok -> Octokit.newAuthOctokit tok
      AppM.runAppM { octokit, manifestDir: dir, gitBranch: branch, tmpDir: tmp } do
        pursManifest <- readPursManifest
        pursUpdates <- fetchPursReleases (Set.unions $ map Map.keys $ Map.values pursManifest)
        let pursUpdateCount = Map.size pursUpdates

        spagoManifest <- readSpagoManifest
        spagoUpdates <- fetchSpagoReleases
        let spagoUpdateCount = Map.size spagoUpdates

        when (pursUpdateCount + spagoUpdateCount == 0) do
          Console.log "No updates!"
          liftEffect (Process.exit 0)

        case commit of
          NoCommit -> do
            Console.log "Updating locally only (not committing results)"

            if pursUpdateCount > 0 then do
              Console.log $ "New purs releases: " <> Utils.printJson Nix.Manifest.pursManifestCodec pursUpdates
              Console.log "Writing to disk..."
              let merged = Map.unionWith Map.union pursManifest pursUpdates
              writePursManifest merged
            else do
              Console.log "No new purs releases."

            if spagoUpdateCount > 0 then do
              Console.log $ "New spago releases: " <> Utils.printJson Nix.Manifest.spagoManifestCodec spagoUpdates
              Console.log "Writing to disk..."
              let merged = Map.union spagoManifest spagoUpdates
              writeSpagoManifest merged
            else do
              Console.log "No new spago releases."

          DoCommit -> do
            Console.log "Cloning purescript-nix, opening a branch, committing, and opening a pull request..."
            token <- Env.lookupRequired Env.githubToken
            gitCommitResult <- AppM.runGitM do
              Git.gitCloneUpstream

              if pursUpdateCount > 0 then do
                let merged = Map.unionWith Map.union pursManifest pursUpdates
                Utils.writeJsonFile (Path.concat [ tmp, "purescript-nix", "manifests", "purs.json" ]) Nix.Manifest.pursManifestCodec merged
              else do
                Console.log "No new purs releases."
              if spagoUpdateCount > 0 then do
                let merged = Map.union spagoManifest spagoUpdates
                Utils.writeJsonFile (Path.concat [ tmp, "purescript-nix", "manifests", "spago.json" ]) Nix.Manifest.spagoManifestCodec merged
              else do
                Console.log "No new spago releases."

              -- TODO: Commit message could be a lot more informative.
              Git.gitCommitManifests "Update manifests" >>= case _ of
                Git.NothingToCommit -> do
                  Console.log "No files were changed, not committing."
                  liftEffect (Process.exit 1)
                Git.Committed ->
                  Console.log "Committed changes!"

            case gitCommitResult of
              Left error -> do
                Console.log error
                liftEffect (Process.exit 1)
              Right _ -> pure unit

            let
              pursVersions = Set.unions $ map Map.keys $ Map.values pursUpdates
              spagoVersions = Map.keys spagoUpdates
              title = "Update " <> String.joinWith " "
                [ guard (Set.size pursVersions > 0) $ "purs (" <> String.joinWith ", " (Set.toUnfoldable (Set.map Nix.Version.print pursVersions)) <> ")"
                , guard (Set.size spagoVersions > 0) $ "spago (" <> String.joinWith ", " (Set.toUnfoldable (Set.map Nix.Version.print spagoVersions)) <> ")"
                ]
              -- TODO: What would be the most informative thing to do here?
              body = "Update manifest files to new tooling versions."

            existing <- AppM.runGitHubM GitHub.getPullRequests >>= case _ of
              Left error -> do
                Console.log $ Octokit.printGitHubError error
                liftEffect (Process.exit 1)
              Right existing -> pure existing

            -- TODO: Title comparison is a bit simplistic. Better to compare
            -- on like the new hashes or something?
            createPullResult <- case Array.find (eq title <<< _.title) existing of
              Nothing -> do
                pushResult <- AppM.runGitM $ Git.gitPushBranch token >>= case _ of
                  Git.NothingToPush -> do
                    Console.log "Did not push branch because we're up-to-date (expected to push change)."
                    liftEffect (Process.exit 1)
                  Git.Pushed ->
                    Console.log "Pushed changes!"
                case pushResult of
                  Left error -> do
                    Console.log error
                    liftEffect (Process.exit 1)
                  Right _ ->
                    AppM.runGitHubM $ GitHub.createPullRequest { title, body, branch }

              Just pull -> do
                Console.log "A pull request with this title is already open: "
                Console.log pull.url
                liftEffect (Process.exit 1)

            case createPullResult of
              Left error -> do
                Console.log "Failed to create pull request:"
                Console.log $ Octokit.printGitHubError error
                liftEffect (Process.exit 1)
              Right { url } -> do
                Console.log "Successfully created pull request!"
                Console.log url

-- | Fetch all releases from the PureScript compiler repository and format them
-- | as Nix-compatible manifests.
fetchPursReleases :: Set NixVersion -> AppM PursManifest
fetchPursReleases existing = do
  Console.log "Fetching purs releases..."
  eitherReleases <- AppM.runGitHubM $ GitHub.listReleases PursRepo
  case eitherReleases of
    Left error -> do
      Console.log "Failed to fetch purs releases:"
      Console.log $ Octokit.printGitHubError error
      liftEffect (Process.exit 1)
    Right releases -> do
      manifests <- map Array.catMaybes $ traverse (pursReleaseToManifest existing) releases
      pure $ Array.foldl (Map.unionWith Map.union) Map.empty manifests

omittedPursReleases :: Array Tag
omittedPursReleases =
  [ Tag "v0.13.1" -- https://github.com/purescript/purescript/releases/tag/v0.13.1 (doesn't work)
  , Tag "v0.13.7" -- https://github.com/purescript/purescript/releases/tag/v0.13.7 (has no releases)
  , Tag "v0.15.1" -- https://github.com/purescript/purescript/releases/tag/v0.15.1 (incorrect version number, identical to 0.15.2)
  ]

isPre0_13 :: String -> Boolean
isPre0_13 input = do
  let trimmed = fromMaybe input (String.stripPrefix (String.Pattern "v") input)
  fromMaybe false do
    let array = String.split (String.Pattern ".") trimmed
    majorStr <- Array.index array 0
    minorStr <- Array.index array 1
    major <- Int.fromString majorStr
    minor <- Int.fromString minorStr
    pure $ major == 0 && minor < 13

-- | Prerelease versions for x86_64-darwin were incorrect for the 0.15 series
-- | of the compiler up to 0.15.10.
isInvalidDarwinPrerelease :: NixSystem -> NixVersion -> Boolean
isInvalidDarwinPrerelease system (NixVersion { version, pre }) = do
  if system == X86_64_darwin then case pre of
    Nothing -> false
    Just _ -> Version.patch version < 10
  else
    false

isSupportedAsset :: ReleaseAsset -> Boolean
isSupportedAsset asset = do
  isJust (String.stripSuffix (String.Pattern ".tar.gz") asset.name)
    && not (String.contains (String.Pattern "win64") asset.name)

-- | Convert a release to a manifest, returning Nothing if the release ought to
-- | be skipped.
pursReleaseToManifest :: Set NixVersion -> Release -> AppM (Maybe PursManifest)
pursReleaseToManifest existing release = do
  Console.log $ "\nProcessing release " <> release.tag
  if isPre0_13 release.tag then do
    Console.log $ "Omitting release " <> release.tag <> " because it is prior to purs-0.13"
    pure Nothing
  else if Array.any (\(Tag omitted) -> release.tag == omitted) omittedPursReleases then do
    Console.log $ "Omitting release " <> release.tag <> " because it is in the omitted purs releases list."
    pure Nothing
  else if release.draft then do
    Console.log $ "Omitting release " <> release.tag <> " because it is a draft."
    pure Nothing
  else case Nix.Version.parse $ fromMaybe release.tag $ String.stripPrefix (String.Pattern "v") release.tag of
    Left error -> do
      Console.log $ "Skipping release because it could not be parsed as a Nix version (X.Y.Z or X.Y.Z-N)."
      Console.log error
      pure Nothing
    Right version
      | Set.member version existing -> do
          Console.log $ "Skipping release because it already exists in the manifests file."
          pure Nothing
      | otherwise -> do
          let supportedAssets = Array.filter isSupportedAsset release.assets
          when (Array.length supportedAssets < 2) do
            Console.log "PureScript releases always have at least 2 supported release assets, but this release has fewer."
            Console.log $ Utils.printJson Octokit.releaseCodec release
            liftEffect (Process.exit 1)
          entries :: Array (Maybe (Tuple NixSystem FetchUrl)) <- for supportedAssets \tarball -> do
            system <- case Nix.System.fromPursReleaseTarball tarball.name of
              Left error -> do
                Console.log $ "Failed to parse tarball in release " <> release.tag <> " named " <> tarball.name
                Console.log error
                liftEffect (Process.exit 1)
              Right system -> pure system
            Console.log $ "Chose Nix system " <> Nix.System.print system <> " for tarball " <> tarball.name
            if isInvalidDarwinPrerelease system version then do
              Console.log "This version has an invalid prerelease version on darwin, skipping for that system."
              pure Nothing
            else do
              sha256 <- Nix.Prefetch.nixPrefetchTarball tarball.downloadUrl >>= case _ of
                Left error -> do
                  Console.log $ "Could not prefetch hash for tarball at url " <> tarball.downloadUrl
                  Console.log error
                  liftEffect (Process.exit 1)
                Right sha256 -> pure sha256
              Console.log $ "Got hash " <> Sha256.print sha256 <> " for tarball " <> tarball.name
              pure (Just (Tuple system { url: tarball.downloadUrl, hash: sha256 }))
          let union prev (Tuple system entry) = Map.insertWith Map.union system (Map.singleton version entry) prev
          pure $ Just $ Array.foldl union Map.empty $ Array.catMaybes entries

-- TODO: Spago's alpha does not currently have any official releases, so we
-- don't fetch anything.
--
-- TODO: Actually, fetch the releases, and decide based on the tag whether to
-- use the fetchurl approach or use the git rev approach.
fetchSpagoReleases :: AppM SpagoManifest
fetchSpagoReleases = do
  Console.log "Fetching spago releases..."
  pure Map.empty

getPursManifestPath :: AppM FilePath
getPursManifestPath = do
  { manifestDir } <- ask
  pure $ Path.concat [ manifestDir, "purs.json" ]

getSpagoManifestPath :: AppM FilePath
getSpagoManifestPath = do
  { manifestDir } <- ask
  pure $ Path.concat [ manifestDir, "spago.json" ]

readPursManifest :: AppM PursManifest
readPursManifest = do
  path <- getPursManifestPath
  Utils.readJsonFile path Nix.Manifest.pursManifestCodec

writePursManifest :: PursManifest -> AppM Unit
writePursManifest manifest = do
  path <- getPursManifestPath
  Utils.writeJsonFile path Nix.Manifest.pursManifestCodec manifest

readSpagoManifest :: AppM SpagoManifest
readSpagoManifest = do
  path <- getSpagoManifestPath
  Utils.readJsonFile path Nix.Manifest.spagoManifestCodec

writeSpagoManifest :: SpagoManifest -> AppM Unit
writeSpagoManifest manifest = do
  path <- getPursManifestPath
  Utils.writeJsonFile path Nix.Manifest.spagoManifestCodec manifest
