-- | Bash script and input parsing.
module Language.Bash.Parse
    ( parse
    ) where

import           Control.Applicative          hiding (many)
import           Control.Monad
import           Data.Either
import           Data.Functor.Identity
import           Text.Parsec.Char             hiding (newline)
import           Text.Parsec.Combinator       hiding (optional)
import           Text.Parsec.Error            (ParseError)
import           Text.Parsec.Pos
import           Text.Parsec.Prim             hiding (parse, (<|>))

import qualified Language.Bash.Parse.Internal as I
import           Language.Bash.Parse.Packrat
import           Language.Bash.Syntax

-- | User state.
data U = U { postHeredoc :: Maybe (State D U) }

-- | Bash parser type.
type Parser = ParsecT D U Identity

-- | Parse a script or input line into a (possibly empty) list of commands.
parse :: SourceName -> String -> Either ParseError List
parse source = runParser script (U Nothing) source . pack (initialPos source)

-------------------------------------------------------------------------------
-- Basic parsers
-------------------------------------------------------------------------------

infixl 3 </>
infix  0 ?:

-- | Backtracking choice.
(</>) :: ParsecT s u m a -> ParsecT s u m a -> ParsecT s u m a
p </> q = try p <|> q

-- | Name a parser from the front.
(?:) :: String -> ParsecT s u m a -> ParsecT s u m a
(?:) = flip (<?>)

-- | Get the next line of input.
line :: Parser String
line = lookAhead anyChar *> many (satisfy (/= '\n')) <* optional (char '\n')

-- | Parse the next here document.
heredoc :: Bool -> String -> Parser String
heredoc strip end = "here document" ?: do
    (h, s) <- lookAhead duck
    setState $ U (Just s)
    return h
  where
    process = if strip then dropWhile (== '\t') else id

    duck = do
        u <- getState
        case postHeredoc u of
            Nothing -> () <$ line
            Just s  -> () <$ setParserState s
        h <- unlines <$> heredocLines
        s <- getParserState
        return (h, s)

    heredocLines = do
        l <- process <$> line
        if l == end then return [] else (l :) <$> heredocLines

-- | Parse a newline, skipping any here documents.
newline :: Parser String
newline = "newline" ?: do
    _ <- char '\n'
    u <- getState
    case postHeredoc u of
        Nothing -> return ()
        Just s  -> () <$ setParserState s
    setState $ U Nothing
    return "\n"

-- | Parse a list terminator.
listTerm :: Parser ListTerm
listTerm = term <* newlineList <?> "list terminator"
  where
    term = Sequential   <$ newline
       <|> Sequential   <$ operator ";"
       <|> Asynchronous <$ operator "&"

-- | Skip zero or more newlines.
newlineList :: Parser ()
newlineList = skipMany newline

-------------------------------------------------------------------------------
-- Simple commands
-------------------------------------------------------------------------------

-- | Skip a redirection.
redir :: Parser Redir
redir = normalRedir
    <|> heredocRedir
    <?> "redirection"
  where
    normalRedir = do
        desc   <- optional ioDesc
        op     <- redirOperator
        target <- anyWord
        return $ Redir
            { redirDesc   = desc
            , redirOp     = op
            , redirTarget = target
            }

    heredocRedir = do
        (strip, op) <- heredocOperator
        w <- anyWord
        let delim = I.unquote w
        h <- heredoc strip delim
        return $ Heredoc
            { redirOp            = op
            , heredocDelim       = delim
            , heredocDelimQuoted = delim /= w
            , document           = h
            }

    heredocOperator = (,) False <$> operator "<<"
                  <|> (,) True  <$> operator "<<-"

-- | Skip a list of redirections.
redirList :: Parser [Redir]
redirList = many redir

-- | Parse part of a command.
commandParts :: Parser a -> Parser ([a], [Redir])
commandParts p = partitionEithers <$> many part
  where
    part = Left  <$> p
       <|> Right <$> redir

-- | Parse a simple command.
simpleCommand :: Parser Command
simpleCommand = do
    notFollowedBy reservedWord
    normalCommand </> assignCommand
  where
    normalCommand = "simple command" ?: do
        (as, rs1) <- commandParts assign
        (ws, rs2) <- commandParts anyWord
        guard (not $ null as && null ws)
        return $ Command (SimpleCommand as ws) (rs1 ++ rs2)

    assignCommand = "assignment builtin" ?: do
        rs1 <- redirList
        w <- assignBuiltin
        (args, rs2) <- commandParts assignArg
        return $ Command (AssignBuiltin w args) (rs1 ++ rs2)

    assignArg = Left  <$> assign
            <|> Right <$> anyWord

-------------------------------------------------------------------------------
-- Lists
-------------------------------------------------------------------------------

-- | A list with one command.
singleton :: ShellCommand -> List
singleton c =
    List [Statement (Last (unmodifiedPipeline [Command c []])) Sequential]

-- | An unmodified pipeline.
unmodifiedPipeline :: [Command] -> Pipeline
unmodifiedPipeline cs = Pipeline
    { timed      = False
    , timedPosix = False
    , inverted   = False
    , commands   = cs
    }

-- | Parse a pipeline.
pipelineCommand :: Parser Pipeline
pipelineCommand = time
              <|> invert
              <|> pipeline1
              <?> "pipeline"
  where
    invert = do
        _ <- word "!"
        p <- pipeline0
        return $ p { inverted = not (inverted p) }

    time = do
        _ <- word "time"
        p <- posixFlag <|> invert <|> pipeline0
        return $ p { timed = True }

    posixFlag = do
        _ <- word "-p"
        _ <- optional (word "--")
        p <- invert <|> pipeline0
        return $ p { timedPosix = True }

    pipeline0 = unmodifiedPipeline <$> commandList0
    pipeline1 = unmodifiedPipeline <$> commandList1

    commandList0 = option [] commandList1
    commandList1 = do
        c <- command
        pipelineSep c <|> pure [c]

    pipelineSep c = do
        c' <- c          <$ operator "|"
          <|> addRedir c <$ operator "|&"
        (c' :) <$> commandList0

    addRedir (Command c rs) = Command c (stderrRedir : rs)

    stderrRedir = Redir (Just (IONumber 2)) ">&" "1"

-- | Parse a compound list of commands.
compoundList :: Parser List
compoundList = List <$ newlineList <*> many1 statement <?> "list"
  where
    statement = Statement <$> andOr <*> option Sequential listTerm

    andOr = do
        p <- pipelineCommand
        let rest = And p <$ operator "&&" <* newlineList <*> andOr
               <|> Or  p <$ operator "||" <* newlineList <*> andOr
        rest <|> pure (Last p)

-- | Parse a possible empty compound list of commands.
inputList :: Parser List
inputList = newlineList *> option (List []) compoundList

-- | Parse a command group, wrapped either in braces or in a @do...done@ block.
doGroup :: Parser List
doGroup = word "do" *> compoundList <* word "done"
      <|> word "{"  *> compoundList <* word "}"

-------------------------------------------------------------------------------
-- Compound commands
-------------------------------------------------------------------------------

-- | Parse a compound command.
shellCommand :: Parser ShellCommand
shellCommand = group
           <|> ifCommand
           <|> caseCommand
           <|> forCommand
           <|> whileCommand
           <|> untilCommand
           <|> selectCommand
           <|> condCommand
           <|> arithCommand
           <|> subshell
           <?> "compound command"

-- | Parse a @case@ command.
caseCommand :: Parser ShellCommand
caseCommand = Case <$ word "case"
          <*> anyWord <* newlineList
          <*  word "in" <* newlineList
          <*> clauses
  where
    clauses = [] <$ word "esac"
          <|> do p <- pattern
                 c <- inputList
                 nextClause (CaseClause p c)

    nextClause f = (:) <$> (f <$> clauseTerm) <* newlineList <*> clauses
               <|> [f Break] <$ newlineList <* word "esac"

    pattern = optional (operator "(")
           *> anyWord `sepBy` operator "|"
          <*  operator ")"
          <?> "pattern list"

    clauseTerm = Break       <$ operator ";;"
             <|> FallThrough <$ operator ";&"
             <|> Continue    <$ operator ";;&"
             <?> "case clause terminator"

-- | Parse a @while@ command.
whileCommand :: Parser ShellCommand
whileCommand = While <$ word "while"
           <*> compoundList
           <*  word "do" <*> compoundList <* word "done"

-- | Parse an @until@ command.
untilCommand :: Parser ShellCommand
untilCommand = Until <$ word "until"
           <*> compoundList
           <*  word "do" <*> compoundList <* word "done"

-- | Parse a list of words for a @for@ or @select@ command.
wordList :: Parser [Word]
wordList = ["$@\""] <$ operator ";" <* newlineList
       <|> newlineList *> inList
       <?> "word list"
  where
    inList = word "in" *> many anyWord <* listTerm
         <|> return ["$@\""]

-- | Parse a @for@ command.
forCommand :: Parser ShellCommand
forCommand = word "for" *> (arithFor_ <|> for_)
  where
    arithFor_ = ArithFor <$> arith <* optional listTerm <*> doGroup

    for_ = For <$> anyWord <*> wordList <*> doGroup

-- | Parse a @select@ command.
selectCommand :: Parser ShellCommand
selectCommand = Select <$ word "select" <*> anyWord <*> wordList <*> doGroup

-- | Parse an @if@ command.
ifCommand :: Parser ShellCommand
ifCommand = word "if" *> if_
  where
    if_ = If <$> compoundList <* word "then" <*> compoundList <*> alternative

    alternative = Just . singleton <$ word "elif" <*> if_
              <|> Just             <$ word "else" <*> compoundList <* word "fi"
              <|> Nothing          <$ word "fi"

-- | Parse a subshell command.
subshell :: Parser ShellCommand
subshell = Subshell <$ operator "(" <*> compoundList <* operator ")"

-- | Parse a command group.
group :: Parser ShellCommand
group = Group <$ word "{" <*> compoundList <* word "}"

-- | Parse an arithmetic command.
arithCommand :: Parser ShellCommand
arithCommand = Arith <$> arith

-- | Parse a conditional command.
condCommand :: Parser ShellCommand
condCommand = Cond <$ word "[[" <*> many1 condPart <* word "]]"
  where
    condPart = anyWord <|> anyOperator

-------------------------------------------------------------------------------
-- Coprocesses
-------------------------------------------------------------------------------

-- | Parse a coprocess command.
coproc :: Parser ShellCommand
coproc = word "coproc" *> coprocCommand <?> "coprocess"
  where
    coprocCommand = Coproc <$> option "COPROC" name
                           <*> (Command <$> shellCommand <*> pure [])
                </> Coproc "COPROC" <$> simpleCommand

-------------------------------------------------------------------------------
-- Function definitions
-------------------------------------------------------------------------------

-- | Parse a function definition.
functionDef :: Parser ShellCommand
functionDef = functionDef2
          </> functionDef1
          <?> "function definition"
  where
    functionDef1 = FunctionDef <$ word "function" <*> anyWord
               <*  optional functionParens <* newlineList
               <*> functionBody

    functionDef2 = FunctionDef <$> unreservedWord
               <*  functionParens <* newlineList
               <*> functionBody

    functionParens = operator "(" <* operator ")"

    functionBody = unwrap <$> group
               <|> singleton <$> shellCommand

    unwrap (Group l) = l
    unwrap _         = List []

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

-- | Parse a single command.
command :: Parser Command
command = Command <$> compoundCommand <*> redirList
      <|> simpleCommand
      <?> "command"
  where
    compoundCommand = shellCommand
                  <|> coproc
                  <|> functionDef

-- | Parse an entire script (e.g. a file) as a list of commands.
script :: Parser List
script = skipSpace *> inputList <* eof
