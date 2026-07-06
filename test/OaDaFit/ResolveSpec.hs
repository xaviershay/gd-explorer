module OaDaFit.ResolveSpec (spec) where

import Test.Hspec
import Data.Text (Text)
import qualified Data.Text as T
import OaDaFit.Resolve (resolveMatch)

data C = C { cName :: Text, cHealth :: Double }

resolve :: Text -> Double -> [C] -> Maybe C
resolve = resolveMatch cName cHealth

spec :: Spec
spec = describe "resolveMatch" $ do
  it "matches a single candidate case-insensitively" $ do
    let candidates = [C (T.pack "Shield") 4302]
    fmap cName (resolve (T.pack "shield") 4302 candidates) `shouldBe` Just (T.pack "Shield")

  it "returns Nothing when no candidate's name matches" $ do
    let candidates = [C (T.pack "Shield") 4302]
    resolve (T.pack "Snake Eyes") 4302 candidates `shouldBe` Nothing

  it "picks the duplicate-named candidate whose health is closest to observed (near the first)" $ do
    let candidates = [C (T.pack "Shield") 4302, C (T.pack "Shield") 9999]
    fmap cHealth (resolve (T.pack "shield") 4302 candidates) `shouldBe` Just 4302

  it "picks the duplicate-named candidate whose health is closest to observed (near the second)" $ do
    let candidates = [C (T.pack "Shield") 4302, C (T.pack "Shield") 9999]
    fmap cHealth (resolve (T.pack "shield") 9999 candidates) `shouldBe` Just 9999

  it "picks the nearer candidate when observed health falls between the two" $ do
    let candidates = [C (T.pack "Shield") 4302, C (T.pack "Shield") 9999]
    fmap cHealth (resolve (T.pack "shield") 8000 candidates) `shouldBe` Just 9999

instance Eq C where
  a == b = cName a == cName b && cHealth a == cHealth b

instance Show C where
  show c = T.unpack (cName c) ++ " " ++ show (cHealth c)
