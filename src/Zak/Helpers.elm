module Zak.Helpers exposing (describeRuntimeError, describeRuntimeErrorAt, formatError)

{-| Error formatting (`formatError`, `describeRuntimeError`): turning a
`Zak.Internal.Interpreter.Error` or a `RuntimeError` into text a person can read.
The text itself comes from `Zak.Internal.ErrorMessage`.
-}

import Zak.Internal.ErrorMessage as ErrorMessage
import Zak.Internal.Interpreter as Interpreter exposing (Error)
import Zak.Internal.Runtime exposing (RuntimeError)


{-| A one-line, plain-English description of a `Zak.Internal.Interpreter.Error`,
plus the exact source line it happened on with a `^` under the column it
happened at — readable, unlike `Debug.toString`, which only ever dumps
the raw constructor tree (fine for a test's own `Expect.equal`, useless
for a person actually looking at the error).
-}
formatError : String -> Error -> String
formatError source error =
    case error of
        Interpreter.SyntaxError deadEnds ->
            ErrorMessage.formatSyntaxError source deadEnds

        Interpreter.RuntimeError runtimeError ->
            ErrorMessage.formatRuntimeError source runtimeError


{-| See `Zak.Internal.ErrorMessage.describeRuntimeErrorAt`.
-}
describeRuntimeErrorAt : RuntimeError -> String
describeRuntimeErrorAt =
    ErrorMessage.describeRuntimeErrorAt


{-| See `Zak.Internal.ErrorMessage.describeRuntimeError`.
-}
describeRuntimeError : RuntimeError -> String
describeRuntimeError =
    ErrorMessage.describeRuntimeError
