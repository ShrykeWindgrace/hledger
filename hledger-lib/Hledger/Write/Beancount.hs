{-|
Helpers for beancount output.
-}

{-# LANGUAGE OverloadedStrings    #-}

module Hledger.Write.Beancount (
  showTransactionBeancount,
  -- postingsAsLinesBeancount,
  -- postingAsLinesBeancount,
  -- showAccountNameBeancount,
  accountNameToBeancount,
  -- beancountTopLevelAccounts,

  -- * Tests
  tests_WriteBeancount
)
where

-- import Prelude hiding (Applicative(..))
import Data.Char
import Data.Default (def)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TB
import Safe (maximumBound)
import Text.DocLayout (realLength)
import Text.Tabular.AsciiWide hiding (render)

import Hledger.Utils
import Hledger.Data.Types
import Hledger.Data.AccountName
import Hledger.Data.Amount
import Hledger.Data.Dates (showDate)
import Hledger.Data.Posting (renderCommentLines, showBalanceAssertion, postingIndent)
import Hledger.Data.Transaction (payeeAndNoteFromDescription')

--- ** doctest setup
-- $setup
-- >>> :set -XOverloadedStrings

-- | Like showTransaction, but generates Beancount journal format.
showTransactionBeancount :: Transaction -> Text
showTransactionBeancount t =
  -- https://beancount.github.io/docs/beancount_language_syntax.html
  -- similar to showTransactionHelper, but I haven't bothered with Builder
     firstline <> nl
  <> foldMap ((<> nl)) newlinecomments
  <> foldMap ((<> nl)) (postingsAsLinesBeancount $ tpostings t)
  <> nl
  where
    nl = "\n"
    firstline = T.concat [date, status, payee, note, tags, samelinecomment]
    date = showDate $ tdate t
    status = if tstatus t == Pending then " !" else " *"
    (payee,note) =
      case payeeAndNoteFromDescription' $ tdescription t of
        ("","") -> ("",      ""      )
        ("",n ) -> (""     , wrapq n )
        (p ,"") -> (wrapq p, wrapq "")
        (p ,n ) -> (wrapq p, wrapq n )
      where
        wrapq = wrap " \"" "\"" . escapeDoubleQuotes . escapeBackslash
    tags = T.concat $ map ((" #"<>).fst) $ ttags t
    (samelinecomment, newlinecomments) =
      case renderCommentLines (tcomment t) of []   -> ("",[])
                                              c:cs -> (c,cs)

-- | Like postingsAsLines but generates Beancount journal format.
postingsAsLinesBeancount :: [Posting] -> [Text]
postingsAsLinesBeancount ps = concatMap first3 linesWithWidths
  where
    linesWithWidths = map (postingAsLinesBeancount False maxacctwidth maxamtwidth) ps
    maxacctwidth = maximumBound 0 $ map second3 linesWithWidths
    maxamtwidth  = maximumBound 0 $ map third3  linesWithWidths

-- | Like postingAsLines but generates Beancount journal format.
postingAsLinesBeancount  :: Bool -> Int -> Int -> Posting -> ([Text], Int, Int)
postingAsLinesBeancount elideamount acctwidth amtwidth p =
    (concatMap (++ newlinecomments) postingblocks, thisacctwidth, thisamtwidth)
  where
    -- This needs to be converted to strict Text in order to strip trailing
    -- spaces. This adds a small amount of inefficiency, and the only difference
    -- is whether there are trailing spaces in print (and related) reports. This
    -- could be removed and we could just keep everything as a Text Builder, but
    -- would require adding trailing spaces to 42 failing tests.
    postingblocks = [map T.stripEnd . T.lines . TL.toStrict $
                       render [ textCell BottomLeft statusandaccount
                              , textCell BottomLeft "  "
                              , Cell BottomLeft [pad amt]
                              , textCell BottomLeft samelinecomment
                              ]
                    | (amt,_assertion) <- shownAmountsAssertions]
    render = renderRow def{tableBorders=False, borderSpaces=False} . Group NoLine . map Header
    pad amt = WideBuilder (TB.fromText $ T.replicate w " ") w <> amt
      where w = max 12 amtwidth - wbWidth amt  -- min. 12 for backwards compatibility

    pacct = showAccountNameBeancount Nothing $ paccount p
    pstatusandacct p' = if pstatus p' == Pending then "! " else "" <> pacct

    -- currently prices are considered part of the amount string when right-aligning amounts
    -- Since we will usually be calling this function with the knot tied between
    -- amtwidth and thisamtwidth, make sure thisamtwidth does not depend on
    -- amtwidth at all.
    shownAmounts
      | elideamount = [mempty]
      | otherwise   = showMixedAmountLinesB displayopts a'
        where
          displayopts = defaultFmt{ displayZeroCommodity=True, displayForceDecimalMark=True }
          a' = mapMixedAmount amountToBeancount $ pamount p
    thisamtwidth = maximumBound 0 $ map wbWidth shownAmounts

    -- when there is a balance assertion, show it only on the last posting line
    shownAmountsAssertions = zip shownAmounts shownAssertions
      where
        shownAssertions = replicate (length shownAmounts - 1) mempty ++ [assertion]
          where
            assertion = maybe mempty ((WideBuilder (TB.singleton ' ') 1 <>).showBalanceAssertion) $ pbalanceassertion p

    -- pad to the maximum account name width, plus 2 to leave room for status flags, to keep amounts aligned
    statusandaccount = postingIndent . fitText (Just $ 2 + acctwidth) Nothing False True $ pstatusandacct p
    thisacctwidth = realLength pacct

    (samelinecomment, newlinecomments) =
      case renderCommentLines (pcomment p) of []   -> ("",[])
                                              c:cs -> (c,cs)

-- | Like showAccountName for Beancount journal format.
-- Calls accountNameToBeancount first.
showAccountNameBeancount :: Maybe Int -> AccountName -> Text
showAccountNameBeancount w = maybe id T.take w . accountNameToBeancount

type BeancountAccountName = AccountName
type BeancountAccountNameComponent = AccountName

-- | Convert a hledger account name to a valid Beancount account name.
-- It replaces non-supported characters with @-@ (warning: in extreme cases
-- separate accounts could end up with the same name), it prepends the letter B
-- to any part which doesn't begin with a letter or number, and it capitalises
-- each part. It also checks that the first part is one of the required english
-- account names Assets, Liabilities, Equity, Income, or Expenses, and if not
-- it raises an informative error suggesting --alias.
-- Ref: https://beancount.github.io/docs/beancount_language_syntax.html#accounts
accountNameToBeancount :: AccountName -> BeancountAccountName
accountNameToBeancount a =
  dbg9 "beancount account name" $
  accountNameFromComponents bs'
  where
    bs =
      map accountNameComponentToBeancount $ accountNameComponents $
      dbg9 "hledger account name  " $
      a
    bs' =
      case bs of
        b:_ | b `notElem` beancountTopLevelAccounts -> error' e
          where
            e = T.unpack $ T.unlines [
              "bad top-level account: " <> b
              ,"in beancount account name:           " <> accountNameFromComponents bs
              ,"converted from hledger account name: " <> a
              ,"For Beancount, top-level accounts must be (or be --alias'ed to)"
              ,"one of " <> T.intercalate ", " beancountTopLevelAccounts <> "."
              -- ,"and not: " <> b
              ]
        cs -> cs

accountNameComponentToBeancount :: AccountName -> BeancountAccountNameComponent
accountNameComponentToBeancount acctpart =
  prependStartCharIfNeeded $
  case T.uncons acctpart of
    Nothing -> ""
    Just (c,cs) ->
      textCapitalise $
      T.map (\d -> if isBeancountAccountChar d then d else '-') $ T.cons c cs
  where
    prependStartCharIfNeeded t =
      case T.uncons t of
        Just (c,_) | not $ isBeancountAccountStartChar c -> T.cons beancountAccountDummyStartChar t
        _ -> t

-- | Dummy valid starting character to prepend to Beancount account name parts if needed (B).
beancountAccountDummyStartChar :: Char
beancountAccountDummyStartChar = 'B'

-- XXX these probably allow too much unicode:

-- | Is this a valid character to start a Beancount account name part (capital letter or digit) ?
isBeancountAccountStartChar :: Char -> Bool
isBeancountAccountStartChar c = (isLetter c && isUpperCase c) || isDigit c

-- | Is this a valid character to appear elsewhere in a Beancount account name part (letter, digit, or -) ?
isBeancountAccountChar :: Char -> Bool
isBeancountAccountChar c = isLetter c || isDigit c || c=='-'

beancountTopLevelAccounts = ["Assets", "Liabilities", "Equity", "Income", "Expenses"]

type BeancountAmount = Amount

-- | Do some best effort adjustments to make an amount that renders
-- in a way that Beancount can read: forces the commodity symbol to the right,
-- converts a few currency symbols to names, capitalises all letters.
amountToBeancount :: Amount -> BeancountAmount
amountToBeancount a@Amount{acommodity=c,astyle=s,acost=mp} = a{acommodity=c', astyle=s', acost=mp'}
  -- https://beancount.github.io/docs/beancount_language_syntax.html#commodities-currencies
  where
    c' = T.toUpper $
      T.replace "$" "USD" $
      T.replace "€" "EUR" $
      T.replace "¥" "JPY" $
      T.replace "£" "GBP" $
      c
    s' = s{ascommodityside=R, ascommodityspaced=True}
    mp' = costToBeancount <$> mp
      where
        costToBeancount (TotalCost amt) = TotalCost $ amountToBeancount amt
        costToBeancount (UnitCost  amt) = UnitCost  $ amountToBeancount amt


--- ** tests

tests_WriteBeancount :: TestTree
tests_WriteBeancount = testGroup "Write.Beancount" [
  ]
