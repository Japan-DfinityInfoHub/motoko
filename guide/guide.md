% Language Reference Manual
% [DFINITY Foundation](https://dfinity.org/)

<!---
TODO
* use menhir --only-preprocess-uu parser.mly followed by sed to create concrete grammar
* perhaps use notions of left-evaluation and evaluation to talk about variable deref in just on place?
* perhaps just spell out left-to-right evaluation, trap propagating to avoid all the lurid detail in each expression

TODO:

* [X] *Categorize* primitives and operations as arithmetic (A), logical (L), bitwise (B) and relational (R) and use these categories to concisely present categorized operators (unop, binop, relop, a(ssigning)op) etc.
* [ ] Various inline TBCs and TBRs and TODOs
* [ ] Typing of patterns
* [ ] Variants
* [ ] Object patterns
* [ ] Import expressions
* [ ] Complete draft of Try/Throw expressions and primitive Error/ErrorCode type
* [ ] Prelude
* [ ] Modules and static restriction
* [ ] Type components and paths
* [ ] Prelude (move scattered descriptions of assorted prims like charToText here)
* [ ] Split category R into E (Equality) and O (Ordering) if we don't want Bool to support O.
* [ ] Include actual grammar (extracted from menhir) in appendix?
* [ ] Prose description of definedness checks
* [ ] Platform changes: remove async expressions (and perhaps types); restrict await to shared calls.
* [ ] Queries
* [ ] Remove Shared type
* [ ] Document .vals and .key for arrays. Iter type.
-->

# Introduction

The **internet computer** is a network of connected computers that communicate securely and provide processing services to registered users, developers, and other computers. 
If you think of the internet computer as an infrastructure platform, it is similar to a public cloud provider, like Amazon Web Services (AWS), Google Cloud Platform (GCP), or Microsoft Azure, or a private cloud managed internally by private organizations. 
Unlike a public or private cloud, however, the internet computer platform is not owned and operated by a single private company. 
Its architecture enables multiple computers to operate like one, very powerful, virtual machine that does not depend on legacy technologies that are vulnerable to attack.

### Why develop applications to run on the internet computer?

For programmers and software developers, the internet computer platform provides unique capabilities and opportunities within a framework that simplifies how you can design, build, and deploy applications. 

*{proglang}* is a programming language that has been specifically designed for writing applications, services, and microservices that run on the internet computer platform and that take full advantage of the unique features that the internet computer provides, such as orthogonal persistence, autonomous operation, and tamper-proof message handling. For more information about the unique features of the internet computer along with tutorials and examples to help you develop programs that make use of them, see the _Developer's Guide_.

{proglang} provides:

* A high-level language for programming applications to run on the internet computer platform.

* A simple design that uses familiar syntax that is easy for programmers to learn.

* An *actor-based* programming model optimized for efficient message handling.

* An interpreter and compiler that you can use to test and compile the WebAssembly code for autonomous applications.

* Support for features not-yet implemented that anticipate future extensions and improvement to WebAssembly.

### Why a new language?

The internet computer provides a network platform that can support programs written in different languages. 
The only requirement is that the program must support compilation to WebAssembly code. 
WebAssembly (commonly-abbreviated as Wasm) is a low-level computer instruction format for virtual machines. 
Because WebAssembly code is designed to provide portable low-level instructions that enable applications to be deployed on platforms such as the web, it is a natural fit for deploying applications that are intended to run on the internet computer platform. 
However, most of the higher-level languages--like C, C++, and Rust--that support compiling to WebAssembly are either too unsafe (for example, C or C++) or too complex (for example, Rust) for developers who want to deliver secure applications without a long learning curve.

To address the need for correctness without complexity, {company-id} has designed its own *{proglang}* programming language. *{proglang}* provides a simple and expressive alternative to other programming languages that is easy to learn whether you are a new or experienced programmer.

### Support for other languages

WebAssembly is language-agnostic. 
It does not require a high-level type system for language inter-operation. 
Although {proglang} is specifically designed to compile to WebAssembly and make it easy to write programs to run on the internet computer, it is just one of many languages you can eventually use to develop applications for the internet computer platform.

To support multiple languages and typed, cross-language communication, {company-id} also provides an *Interface Definition Language* (IDL).
The {proglang} compiler automates the production and consumption of IDL files using the type signatures in {proglang} programs and the structure of imported IDL interfaces.

For information about the *Interface Definition Language* interfaces, see XXX.

## Highlights and important features

Although {proglang} is, strictly-speaking, a new language, you might find it is similar to a language you already know. For example, the {proglang} typing system is similar to a functional programming language such as OCaml (Objective Caml), but the syntax you use in defining functions is more like coding in JavaScript.
It also draws on elements that are common in other, more familiar, languages, including JavaScript, TypeScript, C#, Swift, Pony, ML, and Haskell.
Unlike other programming languages, however, {proglang} extends and optimizes features that are uniquely suited to the internet computer platform.

### Actors and objects

One of the most important principles to keep in mind when preparing to use {proglang} is that it is an *actor-based* programming model. 
An actor is a special kind of object with an isolated state that can interacted with remotely and asynchronously.
All communication with and between actors involves passing messages asynchronously over the network using the internet computer's messaging protocol.
An actor’s messages are processed in sequence, so state modifications never cause race conditions.

Classes can be used to produce objects of a predetermined type, with a predetermined interface and behavior. 
Because actors are essentially objects, you can also define actor classes. 
In general, each actor object is used to create one application which is then deployed as a *canister* containing compiled WebAssembly, some environment configuration information, and interface bindings.
For more information about the developing applications and deploying applications, see the _Developer's Guide_.

### Key language features

Some of the other important language features of {proglang} include the following:

* JavaScript/TypeScript-style syntax.
* Bounded polymorphic type system that can assign types without explicit type annotations.
Types can be inferred in many common situations.
Strong, static typing ensures type safety and includes subtype polymorphism, and structural typing.
Unbounded and bounded numeric types with explicit conversions between
them.
Bounded numeric types are checked for overflow.
* Support for imperative programming features, including mutable variables and arrays,
and local control flow constructs, such as loops, `+return+`, `+break+` and
`+continue+`.
* Functions and messages are first-class values.
Pattern-matching is supported for scalar and compound values.
* A simple, class-based object system without inheritance.

* The value of a reference can never implicitly be `+null+` to prevent many common `+null+`-reference failures. Instead, the language enables you to explicitly handle `+null+` values using `+null+`, _option type_ `+?<type>+`.
* Asynchronous message handling enables sequential programming with familiar `+async+` and `+await+` constructs and `promise` replies.

# Lexical conventions

## Whitespace

Space, newline, horizontal tab, carriage return, line feed and form feed (TBR) are considered as whitespace. Whitespace is ignored
but used to separate adjacent keywords, identifiers and operators.


In the definition of some lexemes, we use the symbol `␣` to denote a single whitespace character.

## Comments

Single line comments are all characters following `//` until the end of the same line.

Single or multi-line comments are any sequence of characters delimited by `/*` and  `*/`.

Comments delimited by `/*` and `*/` may be nested, provided the nesting is well-bracketed.

All comments are treated as whitespace.

## Keywords

The following keywords are reserved and may not be used as identifiers:

```bnf
actor and async assert await break case catch class continue debug
else false for func if in import module not null object or label
let loop private public return shared try throw debug_show query
switch true type var while
```

## Identifiers

Identifiers are alpha-numeric, start with a letter and may contain underscores:

```bnf
<id>   ::= Letter (Letter | Digit | _)*
Letter ::= A..Z | a..z
Digit  ::= 0..9
```

## Integers

Integers are written as decimal or hexadecimal, `Ox`-prefixed natural numbers.
Subsequent digits may be prefixed a single, semantically irrelevant, underscore.

```bnf
digit ::= ['0'-'9']
hexdigit ::= ['0'-'9''a'-'f''A'-'F']
num ::= digit ('_'? digit)*
hexnum ::= hexdigit ('_'? hexdigit)*
nat ::= num | "0x" hexnum
```

Negative integers may be constructed by applying a prefix negation `-` operation.

## Characters

A character is a single quote (`'`) delimited:
* Unicode character in UTF-8,
* `\`-escaped  newline, carriage return, tab, single or double quotation mark
* `\`-prefixed ASCII character (TBR),
* or  `\u{` hexnum `}` enclosed valid, escaped Unicode character in hexadecimal (TBR).

```bnf
ascii ::= ['\x00'-'\x7f']
ascii_no_nl ::= ['\x00'-'\x09''\x0b'-'\x7f']
utf8cont ::= ['\x80'-'\xbf']
utf8enc ::=
    ['\xc2'-'\xdf'] utf8cont
  | ['\xe0'] ['\xa0'-'\xbf'] utf8cont
  | ['\xed'] ['\x80'-'\x9f'] utf8cont
  | ['\xe1'-'\xec''\xee'-'\xef'] utf8cont utf8cont
  | ['\xf0'] ['\x90'-'\xbf'] utf8cont utf8cont
  | ['\xf4'] ['\x80'-'\x8f'] utf8cont utf8cont
  | ['\xf1'-'\xf3'] utf8cont utf8cont utf8cont
utf8 ::= ascii | utf8enc
utf8_no_nl ::= ascii_no_nl | utf8enc

escape ::= ['n''r''t''\\''\'''\"']

character ::=
  | [^'"''\\''\x00'-'\x1f''\x7f'-'\xff']
  | utf8enc
  | '\\'escape
  | '\\'hexdigit hexdigit
  | "\\u{" hexnum '}'

char := '\'' character '\''
```

## Text

A text literal is `"`-delimited sequence of characters:

```bnf
text ::= '"' character* '"'
```

## Operators


### Categories

To simplify the presentation of available operators, operators and primitive types are classified into basic categories:


| Abbreviation| Category |          |
|---|----|-------|
| A | Arithmetic | arithmetic operations |
| L | Logical | logical/Boolean operations |
| B | Bitwise | bitwise operations|
| R | Relational | equality and comparison |
| T | Text | concatenation |

Some types have several categories, e.g. type `Int` is both arithmetic (A) and relational (R) and supports both arithmentic addition ('+') and relational less than ('<=') (amongst other operations).

### Unary Operators

| `<unop>`| Category   |          |
|------|----|-------|
| `-`  |  A | numeric negation |
| `+`  |  A | numeric identity |
| `^`  |  B | bitwise negation |



### Relational Operators

| `<relop>` | Category    |          |
|-------|---|------|
| `␣<␣` | R | less than *(must be enclosed in whitespace)* |
| `␣>␣` | R | greater than *(must be enclosed in whitespace)* |
|  `==` | R | equals |
|  `!=` | R | not equals |
|  `<=` | R | less than or equal |
|  `>=` | R | greater than or equal |


Equality is structural.

### Numeric Binary Operators

| `<binop>`| Category    |          |
|------|---|----------|
|  `+` | A | addition |
|  `-` | A | subtraction |
|  `*` | A | multiplication |
|  `/` | A | division |
|  `%` | A | modulo |
|  `**`| A | exponentiation |

### Bitwise Binary Operators

| `<binop>` | Category |          |
|-------|---|------|
| `&`   | B | bitwise and |
| `|`   | B | bitwise or |
| `^`   | B | exclusive or |
| `<<`  | B | shift left |
| `␣>>` | B | shift right *(must be preceded by whitespace)* |
| `<<>` | B | rotate left |
| `<>>` | B | rotate right |

### String Operators

|  `<binop>` | Category |    |
|------|---|------|
|  `#` | T | concatenation |

### Assignment Operators

|`:=`, `<unop>=`, `<binop>=`| Category|          |
|--------| ----|----|
| `:=`   | * | assignment (in place update) |
| `+=`   | A | in place add |
| `-=`   | A | in place subtract |
| `*=`   | A | in place multiply |
| `/=`   | A | in place divide |
| `%=`   | A | in place modulo |
| `**=`  | A | in place exponentiation |
| `&=`   | B | in place logical and |
| `\|=`   | B | in place logical or |
| `^=`   | B | in place exclusive or |
| `<<=`  | B | in place shift left |
| `>>=`  | B | in place shift right |
| `<<>=` | B | in place rotate left |
| `<>>=` | B | in place rotate right |
| `#=`   | T | in place concatenation |

The  category of a compound assigment `<unop>=`/`<binop>=` is given by the category of the operator `<unop>`/`<binop>`.

## Operator and Keyword Precedence

The following table defines the relative precedence and associativity of operators and tokens, ordered from lowest to highest precedence.
Tokens on the same line have equal precedence with the indicated associativity.

Precedence | Associativity | Token |
|---|------------|--------|
LOWEST  | none | `if _ _` (no `else`), `loop _` (no `while`)
|| none | `else`, `while`
|| right | `:= `, `+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `#=`, `&=`, `\|=`, `^=`, `<<=`, `>>-`, `<<>=`, `<>>=`
|| left | `:`
|| left | `or`
|| left | `and`
|| none | `==`, `!=`, `<`, `>`, `<=`, `>`, `>=`
|| left | `+`, `-`, `#`
|| left | `*`, `/`, `%`
|| left | `\|`
|| left | `&`
|| left | `^`
|| none | `<<`, `>>`, `<<>`, `<>>`
HIGHEST | left | `**`


# Types

Type expressions are used to specify the types of arguments, constraints (a.k.a bounds) on type parameters, definitions of type constructors, and the types of sub-expressions in type annotations.

```
<typ> ::=                                     type expressions
  <id> <typ-args>?                              constructor
  <sort>? { <typ-field>;* }                     object
  [ var? <typ> ]                                array
  Null                                          null type
  ? <typ>                                       option
  shared? <typ-params>? <typ> -> <typ>          function
  async <typ>                                   future
  ( ((<id> :)? <typ>),* )                       tuple
  Any                                           top
  None                                          bottom
  Error                                         errors/exceptions
  Shared                                        sharable types
  ( type )                                      parenthesized type

<sort> ::= (actor | module | object)
```

An absent `<sort>?` abbreviates `object`.


## Primitive types

Motoko provides the following primitive type identifiers, including support for Booleans, signed and unsigned integers and machine words of various sizes, characters and text.

The category of a type determines the operators (unary, binary, relational and in-place update via assigment) applicable to values of that type.

| Identifier | Category | Description |
|---|------------|--------|
| `Bool` | L, R | boolean values `true` and `false` and logical operators |
| `Int`  | A, R | signed integer values with arithmetic (unbounded)|
| `Int8`  | A, R | signed 8-bit integer values with checked arithmetic|
| `Int16`  | A, R | signed 16-bit integer values with checked arithmetic|
| `Int32`  | A, R | signed 32-bit integer values with checked arithmetic|
| `Int64`  | A, R | signed 64-bit integer values with checked arithmetic|
| `Nat`  | A, R | non-negative integer values with arithmetic (unbounded)|
| `Nat8`  | A, R | non-negative 8-bit integer values with checked arithmetic|
| `Nat16`  | A, R | non-negative 16-bit integer values with checked arithmetic|
| `Nat32`  | A, R | non-negative 32-bit integer values with checked arithmetic|
| `Nat64`  | A, R | non-negative 64-bit integer values with checked arithmetic|
| `Word8` | A, B, R | unsigned 8-bit integers with bitwise operations |
| `Word16` | A, B, R | unsigned 16-bit integers with bitwise operations |
| `Word32` | A, B, R | unsigned 32-bit integers with bitwise operations |
| `Word64` | A, B, R | unsigned 64-bit integers with bitwise operations |
| `Char` | R | Unicode characters |
| `Text` | T, R | Unicode strings of characters with concatenation `_ # _` |
| `Error` | | (opaque) error values |

### Type `Bool`

The type `Bool` of categories L, R (Logical, Relational) has values `true` and `false` and is supported by one and two branch `if _ <exp> (else <exp>)?`, `not <exp>`, `_ and _` and `_ or _` expressions. Expressions `if`,  `and` and `or` are short-circuiting.

Comparison TODO.

### Type `Char`

A `Char` of category R (Relational) represents characters as a code point in the Unicode character
set. Characters can be converted to `Word32`, and `Word32`s in the
range *0 .. 0x1FFFFF* can be converted to `Char` (the conversion traps
if outside of this range). With `charToText` a character can be
converted into a text of length 1.

### Type `Text`

The type `Text` of categories T and R (Text, Relational) represents sequences of Unicode characters (i.e. strings).
Operations on text values include concatenation (`_ # _`) and sequential iteration over characters via `for (c in _) ... c ...`.
The `textLength` function returns the number of characters in a `Text` value.

Comparison TODO.

### Type `Int` and `Nat`

The types `Int` and `Nat` are signed integral and natural numbers of categories A (Arithmetic) and R (Relational).

Both `Int` and `Nat` are arbitrary precision,
with only subtraction `-` on `Nat` trapping on underflow.

The subtype relation `Nat <: Int` holds, so every expression of type 'Nat' is also an expression of type `Int` (but *not* vice versa).
In particular, every value of type `Nat` is also a value of type `Int`, without change of representation.

### Bounded Integers `Int8`, `Int16`, `Int32` and `Int64`

The types `Int8`, `Int16`, `Int32` and `Int64` represent
signed integers with respectively 8, 16, 32 and 64 bit precision.
All have categories A (Arithmetic) and R (Relational).

Operations that may under- or overflow the representation are checked and trap on error.

### Bounded Naturals `Nat8`, `Nat16`, `Nat32` and `Nat64`

The types `Nat8`, `Nat16`, `Nat32` and `Nat64` represent
unsigned integers with respectively 8, 16, 32 and 64 bit precision.
All have categories A (Arithmetic) and R (Relational).

Operations that may under- or overflow the representation are checked and trap on error.

### Word types

The types `Word8`, `Word16`, `Word32` and `Word64` represent
fixed-width bit patterns of width *n* (8, 16, 32 and 64).
All word types have categories A (Arithmetic), B (Bitwise) and  R (Relational).
As arithmetic types, word types implementing numeric wrap-around
(modulo *2^n*).
As bitwise types, word types support bitwise operations *and* `(&)`,
*or* `(|)` and *exclusive-or* `(^)`. Further, words can be rotated
left `(<<>)`, right `(<>>)`, and shifted left `(<<)`, right `(>>)`,
as well as right with two's-complement sign preserved (`shrs`).
All shift and rotate amounts are considered modulo the word's width
*n*.

Conversions to `Int` and `Nat`, named `word`*n*`ToInt` and
`word`*n*`ToNat`, are exact and expose the word's bit-pattern as
two's complement values, resp. natural numbers. Reverse conversions,
named `intToWord`*n* and `natToWord`*n* are potentially lossy, but the
round-trip property holds modulo *2^n*. The former choose the
two's-complement representation for negative integers.

Word types are not in subtype relationship with each other or with
other arithmetic types, and their literals need type annotation, e.g.
`(-42 : Word16)`. For negative literals the two's-complement
representation is applied.

### Error type

Errors are opaque values constructed using operation
* `error: Text -> Unit`
and examined using operations:
* `errorCode`: `Error -> ErrorCode` (TBC)
* `errorMessage`: `Error -> Text`

(where `ErrorCode` is the prelude defined variant type:

```
type ErrorCode = {#error; #system ; /*...*/ };
```
)

`Error` values can be thrown and caught within an `async` expression or `shared` function (only).

A constructed error `e = error(m)` has `errorCode(e) = #error` and `errorMessage(e)=m`.
Errors with non-`#error` (system) error codes may be caught and thrown, but not constructed.

Note: Exiting an async block or shared function with a system error
exits with a copy of the error with revised code `#error` and the original error message.
This prevents programmatic forgery of system errors. (TBR)

## Constructed types

 `<id> <typ-args>?` is the application of type a identifier, either built-in (i.e. `Int`) or user defined, to zero or more type *arguments*.
 The type arguments must satisfy the bounds, if any, expected by the type constructor's type parameters (see below).

## Object types

`<sort>? { <typ-field>;* }` specifies an object type by listing its zero or more named *type fields*.

Within an object type, the names of fields must be distinct.

Object types that differ only in the ordering of the fields are equivalent.

When `<sort>?` is `actor`, all fields have `shared` function type (specifying messages).

## Variant types

TODO

## Array types

`[ var? <typ> ]` specifies the type of arrays with elements of type `<typ>`.

Arrays are immutable unless specified with qualifier `var`.

## Null type

The `Null` type has a single value, the literal `null`. `Null` is a subtype of the option `? T`, for any type `T`.

## Option types

`? <typ>` specifies the type of values that are either `null` or a proper value of the form `? <v>` where `<v>` has type `typ`.

## Function types

Type `shared? <typ-params>? <typ1> -> <typ2>` specifies the type of functions that consume (optional) type parameters `<typ-params>`, consume a value parameter of type `<typ1>` and produce a result of type `<typ2>`.

Both `<typ1>` and `<typ2>` may reference type parameters declared in `<typ-params>`.

If `<typ1>` or `<typ2>` (or both) is a tuple type, then the length of that tuple type determines the argument or result arity of the function type.

The optional `shared` qualifier specifies whether the function value is shared, which further constrains the form of `<typ-params>`, `<typ1>` and `<typ2>` (see *Sharability* below).

## Async types

`async <typ>` specifies a promise producing a value of a type `<typ>`.

Promise types typically appear as the result type of a `shared` function that produces an `await`-able value.

## Tuple types

`( ((<id> :)? <typ>),* )` specifies the type of a tuple with zero or more ordered components.

The optional identifier `<id>`, naming its components, is for documentation purposes only and cannot be used for component access. In particular, tuple types that differ only in the names of components are equivalent.

## Any type

Type `Any` is the *top* type, i.e. the super-type of all types, (think Object in Java or C#). All values have type 'Any'.

## None type

Type `None` is the *bottom* type, a subtype of all other types.
No value has type `None`.

As an empty type, `None` can be used to specify the impossible return value of an infinite loop or unconditional trap.

## Parenthesised type

A function that takes an immediate, syntactic tuple of length *n >= 0* as its domain or range is a function that takes (respectively returns) *n* values.

When enclosing the argument or result type of a function, which is itself a tuple type,  `( <tuple-typ> )` declares that the function takes or returns a single (boxed) value of type `<tuple-type>`.

In all other positions, `( <typ> )` has the same meaning as `<typ>`.

## Type fields

```bnf
<typ-field> ::=                               object type fields
  <id> : <typ>                                  immutable
  var <id> : <typ>                              mutable
  <id> <typ-params>? <typ1> : <typ2>           function (short-hand)
```

A type field specifies the name and types of fields of an object.

`<id> : <typ>` specifies an *immutable* field, named `<id>` of type `<typ>`.

`var <id> : <typ>` specifies a *mutable* field, named `<id>` of type `<typ>`.

### Sugar

When enclosed by an `actor` object type, `<id> <typ-params>? <typ1> : <typ2>` is syntactic sugar for an immutable field name `<id>` of `shared` function type
`shared <typ-params>? <typ1> -> <typ2>`.

When enclosed by a non-`actor` object type, `<id> <typ-params>? <typ1> : <typ2>` is syntactic sugar for an immutable field name `<id>` of ordinary function type `<typ-params>? <typ1> -> <typ2>`.

## Type parameters

```bnf
<typ-params> ::=                              type parameters
  < typ-param,* >
<typ-param>
  <id> <: <typ>                               constrained type parameter
  <id>                                        unconstrained type parameter
```

A type constructors, function value or function type may be parameterised by a vector of comma-separated, optionally constrained, type parameters.

`<id> <: <typ>` declares a type parameter with constraint `<typ>`.
Any instantiation of `<id>` must subtype `<typ>` (at that same instantiation).

Syntactic sugar `<id>` declares a type parameter with implicit, trivial constraint `Any`.

The names of type parameters in a vector must be distinct.

All type parameters declared in a vector are in scope within its bounds.

## Type arguments

```bnf
<typ-args> ::=                                type arguments
  < <typ>,* >
```
Type constructors and functions may take type arguments.

The number of type arguments must agree with the number of declared type parameters of the function.

Given a vector of type arguments instantiating a vector of type parameters,
each type argument must satisfy the instantiated bounds of the corresponding
type parameter.

## Well-formed types

A type `T` is well-formed only if (recursively) its constituent types are well-formed, and:

* if `T` is `async U` then `U` is shared, and
* if `T` is `shared < ... > V -> W` then `...` is empty, `U` is shared and
  `W == ()` or `W == async W'`, and
* if `T` is `C<T0, ..., TN>` where:
  * a declaration `type C<X0 <: U0, Xn <: Un>  = ...` is in scope, and
  * `Ti <: Ui[ T0/X0, ..., Tn/Xn ]`, for each `0 <= i <= n`.
* if `T` is `actor { ... }` then all fields in `...` are immutable and have `shared` function type.

## Subtyping

Two types `T`, `U` are related by subtyping, written `T <: U`, whenever, one of the following conditions is true:

* `T` equals `U` (reflexivity).

* `U` equals `Any`.

* `T` equals `None`.

* `T` is a type parameter `X` declared with constraint `U`.

* `T`is `Nat` and `U` is `Int`.

* `T` is a tuple `(T0, ..., Tn)`, `U` is a tuple `(U0, ..., Un)`,
    and for each `0 <= i <= n`, `Ti <: Ui`.

* `T` is an immutable array type `[ V ]`, `U` is an immutable array type  `[ W ]`
    and `V <: W`.

* `T` is a mutable array type `[ var T ]`, `V` is a mutable array type  `[ var W ]`
    and `V == W`.

* `T` is `Null` and `U` is an option type `? W` for some 'W'.

* `T` is `? V`, `U` is `? W` and `V <: W`.

* `T` is a promise `async V`, `U` is a promise `async W`,
    and `V <: W`.

* `T` is an object type `sort0 { fts0 }`,
  `U` is an object type `sort1 { fts1 }` and
  * `sort1` == `sort2`, and, for all fields,
  * if field `id : V` is in `fts0` then `id : W` is in `fts1` and `V <: W`, and
  * if mutable field `var id : V` is in `fts0` then  `var id : W` is in `fts1` and `V == W`.

   (That is, object type `T` is a subtype of object type `U` if they have same sort, every mutable field in `U` super-types the same field in `T` and every mutable field in `U` is mutable in `T` with an equivalent type. In particular, `T` may specify more fields than `U`.)

* `T` is a function type `shared? <X0 <: V0, ..., Xn <: Vn> T1 -> T2`,
  `U` is a function type `shared? <X0 <: W0, ..., Xn <: Wn> U1 -> U2` and
  * `T` and `U` are either both `shared` or both non-`shared`, and
  * for all `i`, `Vi <: Wi`, and
  * `U1 <: T1` and
  * `T2 <: U2`.

    (That is, function type `T` is a subtype of function type `U` if they have same sort, they have the same type parameters, every bound in `U` super-types the same parameter bound in `T`, the domain of `U` suptypes the domain of `T` (contra-variance) and the range of `T` subtypes the range of `U`).

* `T` (respectively `U`) is a constructed type `C<V0,...VN>` that is equal, by definition of type constructor `C`,  to `W`, and `W <: U` (respectively `U <: W`).

* For some type `V`, `T <: V` and `V <: U` (*transitivity*).

## Sharability

A type `T` is *shared* if it is
* `Any` or `None`, or
* a primitive type other than `Error`, or
* an option type `? V` where `V` is shared, or
* a tuple type `(T0, ..., Tn)` where all `Ti` are shared, or
* an immutable array type `[V]` where `V` is shared, or
* an object type where all fields are immutable and have shared type, or
* a variant type where all tags have shared type, or
* a `shared` function type.


# Literals

```bnf
<lit> ::=                                     literals
  <nat>                                         natural
  <float>                                       float
  <char>                                        character
  <text>                                        Unicode text
```

Literals are constant values. The syntactic validity of a literal depends on the precision of the type at which it is used.

# Expressions

```bnf
<exp> ::=                                      expressions
  <id>                                           variable
  <lit>                                          literal
  <unop> <exp>                                   unary operator
  <exp> <binop> <exp>                            binary operator
  <exp> <relop> <exp>                            binary relational operator
  ( <exp>,* )                                    tuple
  <exp> . <nat>                                  tuple projection
  ? <exp>                                        option injection
  { <exp-field>;* }                              object
  <exp> . <id>                                   object projection
  <exp> := <exp>                                 assignment
  <unop>= <exp>                                  unary update
  <exp> <binop>= <exp>                           binary update
  [ var? <exp>,* ]                               array
  <exp> [ <exp> ]                                array indexing
  shared? func <func_exp>                        function expression
  <exp> <typ-args>? <exp>                        function call
  { <dec>;* }                                    block
  not <exp>                                      negation
  <exp> and <exp>                                conjunction
  <exp> or <exp>                                 disjunction
  if <exp> <exp> (else <exp>)?                   conditional
  switch <exp> { (case <pat> <exp>;)+ }          switch
  while <exp> <exp>                              while loop
  loop <exp> (while <exp>)?                      loop
  for ( <pat> in <exp> ) <exp>                   iteration
  label <id> (: <typ>)? <exp>                    label
  break <id> <exp>?                              break
  continue <id>                                  continue
  return <exp>?                                  return
  async <exp>                                    async expression
  await <exp>                                    await future (only in async)
  throw <exp>                                    raise an error (only in async)
  try <exp> catch <pat> <exp>                    catch an error (only in async)
  assert <exp>                                   assertion
  <exp> : <typ>                                  type annotation
  dec                                            declaration
  ( <exp> )                                      parentheses
```

## Identifiers

The expression `<id>` evaluates to the value bound to `<id>` in the current evaluation environment.

## Literals

A literal has type 'T' only when its value is within the prescribed range of values of type 'T'.

The literal (or constant) expression `<lit>` evaluates to itself.

## Unary operators

The unary operator `<unop> <exp>` has type `T` provided:

* `<exp>` has type `T`, and
* `<unop>`'s category is a category of `T`.

The unary operator expression `<unop> <exp>` evaluates `exp` to a result. If the result is a value `v`, it returns the result of `<unop> v`.
If the result is a trap, it, too, traps.

## Binary operators

The binary compound assigment `<exp1> <binop> <exp2>` has type `T` provided:

* `<exp1>` has type `T`, and
* `<exp2>` has type `T`, and
* `<binop>`'s category is a category of `T`.

The binary operator expression `<exp1> <binop> <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, the expression results in `trap`.

Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise, `r1`  and `r2` are values `v1` and `v2` and the expression returns
the result of `v1 <binop> v2`.

## Relational operators

The relational expression `<exp1> <relop> <exp2>` has type `Bool` provided:

* `<exp1>` has type `T`, and
* `<exp2>` has type `T`, and
* `<relop>`'s category R is a category of `T`.

The binary operator expression `<exp1> <relop> <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, the expression results in `trap`.

Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise, `r1`  and `r2` are values `v1` and `v2` and the expression returns
the result of `v1 <relop> v2`.

## Tuples

Tuple expression `(<exp1>, ..., <expn>)` has tuple type `(T1, ..., Tn)`, provided
`<exp1>`, ..., `<expN>` have types `T1`, ..., `Tn`.

The tuple expression `(<exp1>, ..., <expn>)` evaluates the expressions `exp1` ... `expn` in order, trapping as soon as some expression `<expi>` traps. If no evaluation traps and `exp1`, ..., `<expn>` evaluate to values `v1`,...,`vn` then the tuple expression returns the tuple value `(v1, ... , vn)`.

The tuple projection `<exp> . <nat>` has type `Ti` provided `<exp>` has tuple type
`(T1, ..., Ti, ..., Tn)`, `<nat>` == `i` and `1 <= i <= n`.

The projection `<exp> . <nat>` evaluates `exp` to a result `r`. If `r` is `trap`, then  the result is `trap`. Otherwise, `r` must be a tuple  `(v1,...,vi,...,vn)` and the result of the projection is the value `vi`.

## Option expressions

The option expression `? <exp>` has type `? T` provided `<exp>` has type `T`.

The literal `null` has type `Null`. Since `Null <: ? T` for any `T`, literal `null` also has type `? T` and signifies the "missing" value at type `? T`.

## Objects

Objects can be written in literal form `{ <exp-field>;* }`, consisting of a list of expression fields:

```bnf
<exp-field> ::= var? <id> = <exp>
```
Such an object literal is equivalent to the object declaration `object { <dec-field>;* }` where the declaration fields are obtained from the expression fields by prefixing each of them with `public let`, or just `public` in case of `var` fields.

## Object projection (Member access)

The object projection `<exp> . <id>` has type `var? T` provided `<exp>` has object type
`sort { var1? <id1> : T1, ..., var? <id> : T, ..., var? <idn> : Tn }` for some sort `sort`.

The object projection `<exp> . <id>` evaluates `exp` to a result `r`. If `r` is `trap`,then the result is `trap`. Otherwise, `r` must be an o
bject value  `{ <id1> = v1,..., id = v, ..., <idn> = vn }` and the result of the projection is the value `v` of field `id`.


If `var` is absent from `var? T` then the value `v` is the constant value of immutable field `<id>`, otherwise:

* if the projection occurs as the target an assignment statement;
  `v` is the mutable location of the field `<id>`.
* otherwise,
  `v` (of type `T`) is the value currently stored in mutable field `<id>`.

## Assignment

The assignment `<exp1> := <exp2>` has type `()` provided:

* `<exp1>` has type `var T`, and
* `<exp2>` has type `T`.

The assignment expression `<exp1> := <exp2>` evaluates `<exp1>` to a result `r1`. If `r1` is `trap`, the expression results in `trap`.

Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise `r1`  and `r2` are (respectively) a location `v1` (a mutable identifier, an item of a mutable array or a mutable field of object) and a value `v2`. The expression updates the current value stored in `v1` with the new value `v2` and returns the empty tuple `()`.

## Unary Compound Assignment

The unary compound assignment `<unop>= <exp>` has type `()` provided:

* `<exp>` has type `var T`, and
* `<unop>`'s category is a category of `T`.

The unary compound assignment
`<unop>= <exp>`  evaluates `<exp>` to a result `r`. If `r` is 'trap' the evaluation traps, otherwise `r` is a location storing value `v` and `r` is updated to
contain the value `<unop> v`.

## Binary Compound Assignment

The binary compound assigment `<exp1> <binop>= <exp2>` has type `()` provided:

* `<exp1>` has type `var T`, and
* `<exp2>` has type `T`, and
* `<binop>`'s category is a category of `T`.

For binary operator `<binop>`, `<exp1> <binop>= <exp1>`,
the compound assignment expression `<exp1> <binop>= <exp2>` evaluates `<exp1>` to a result `r1`. If `r1` is `trap`, the expression results in `trap`.
Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise `r1`  and `r2` are (respectively) a location `v1` (a mutable identifier, an item of a mutable array or a mutable field of object) and a value `v2`. The expression updates the current value, `w` stored in `v1` with the new value `w <binop> v2` and returns the empty tuple `()`.

## Arrays

The expression `[ var? <exp>,* ]` has type `[var? T]` provided
each expression `<exp>` in the sequence `<exp,>*` has type T.

The array expression `[ var <exp0>, ..., <expn> ]` evaluates the expressions `exp0` ... `expn` in order, trapping as soon as some expression `<expi>` traps. If no evaluation traps and `exp0`, ..., `<expn>` evaluate to values `v0`,...,`vn` then the array expression returns the array value `[var? v0, ... , vn]` (of size `n+1`).

The array indexing expression `<exp1> [ <exp2> ]` has type `var? T` provided <exp> has (mutable or immutable) array type `[var? T1]`.

The projection `<exp1> . <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, then the result is `trap`.

Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise, `r1` is an array value, `var? [v0, ..., vn]`, and `r2` is a natural integer `i`. If  'i > n' the index expression returns `trap`.

Otherwise, the index expression returns the value `v`, obtained as follows:

If `var` is absent from `var? T` then the value `v` is the constant value `vi`.

Otherwise,

* if the projection occurs as the target an assignment statement
  then `v` is the `i`th location in the array;
* otherwise,
  `v` is `vi`, the value currently stored in the `i`th location of the array.

## Function Calls

The function call expression `<exp1> <T0,...,Tn>? <exp2>` has type `T` provided

* the function `<exp1>` has function type `shared? < X0 <: V0, ..., Xn <: Vn > U1-> U2`; and
* each type argument satisfies the corresponding type parameter's bounds:
  for each `1<= i <= n`, `Ti <: [T0/X0, ..., Tn/Xn]Vi`; and
* the argument `<exp2>` has type `[T0/X0, ..., Tn/Xn]U1`, and
* `T == [T0/X0, ..., Tn/Xn]U2`.

The call expression `<exp1> <T0,...,Tn>? <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, then the result is `trap`.

Otherwise, `exp2` is evaluated to a result `r2`. If `r2` is `trap`, the expression results in `trap`.

Otherwise, `r1` is a function value, `shared? func <X0 <: V0, ..., n <: Vn> pat { exp }` (for some implicit environment), and `r2` is a value `v2`.
Evaluation continues by matching `v1` against `pat`.
If matching succeeds with some bindings, evaluation proceeds with `exp` using the environment of the function value (not shown) extended with those bindings.
Otherwise, the pattern match has failed and the call results in `trap`.

## Functions

The function expression `shared? func < X0 <: T1, ..., Xn <: Tn > <pat> (: T2)? =?  <exp>` has type `shared? < X0 <: T0, ..., Xn <: Tn > T1-> T2` if, under the
assumption that `X0 <: T1, ..., Xn <: Tn`:

* all the types in `T1, ..., Tn` and `T` are well-formed and well-constrained.
* pattern `pat` has type `T1`;
* expression `<exp>` has type return type `T2` under the assumption that `pat` has type `T1`.

`shared? func <typ-params>? <pat> (: <typ>)? =? <exp>` evaluates to a function
value (a.k.a. closure), denoted `shared? func <typ-params>? <pat> = <exp>`, that stores the code of the function together with the bindings from the current evaluation environment (not shown) needed to evaluate calls to the function value.

## Blocks

The block expression `{ <dec>;* }` has type `T` provided the last declaration in the sequence `<dec>;*` has type `T`.
All identifiers declared in block must be distinct type identifiers or distinct value identifiers and are in scope in the definition of all other declarations in the block.

The bindings of identifiers declared in `{ dec;* }` are local to the block.
The type `T` must be well-formed in the enclosing environment of the block. In particular, any local, recursive types that cannot be expanded to types well-formed the enclosing environment must not appear in `T`.

The type system ensures that a value identifier cannot be evaluated before its declaration has been evaluated, precluding run-time errors at the cost of rejection some well-behaved programs.

Identifiers whose types cannot be inferred from their declaration, but are used in a forward reference, may require an additional type annotation (see Annotated patterns) to satisfy the type checker.

The block expression `{ <dec>;* }` evaluates each declaration in `<dec>;*` in sequence (program order). The first declaration in `<dec>;*` that results in a trap cause the block to result in `trap`, without evaluating subsequent declarations.

## Not

The not expression `not <exp>` has type `Bool` provided `<exp>` has type `Bool`.

If `<exp>` evaluates to `trap`, the expression returns `trap`.
Otherwise, `<exp>` evaluates to a Boolean value `v` and the expression returns `not v`, (the Boolean negation of `v`).

## And

The and expression `<exp1> and <exp2>` has type `Bool` provided `<exp1>` and `<exp2>` have type `Bool`.

The expression `<exp1> and <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, the expression results in `trap`. Otherwise `r1` is a Boolean value `v`.
If `v == false` the expression returns the value `false` (without evaluating `<exp2>`).
Otherwise, the expression returns the result of evaluating `<exp2>`.

## Or

The or expression `<exp1> or <exp2>` has type `Bool` provided `<exp1>` and `<exp2>` have type `Bool`.

The expression `<exp1> and <exp2>` evaluates `exp1` to a result `r1`. If `r1` is `trap`, the expression results in `trap`. Otherwise `r1` is a Boolean value `v`.
If `v == true` the expression returns the value `true` (without evaluating `<exp2>`).
Otherwise, the expression returns the result of evaluating `<exp2>`.

## If

The expression `if <exp1> <exp2> (else <exp3>)?` has type `T` provided:

* `<exp1>` has type `Bool`
* `<exp2>` has type `T`
* `<exp3>` is absent and `() <: T`, or
* `<exp3>` is present and has type `T`.

The expression evaluates `<exp1>` to a result `r1`.
If `r1` is `trap`, the result is  `trap`.
Otherwise, `r1` is the value `true` or `false`.
If `r1` is `true`, the result is the result of evaluating `<exp2>`.
Otherwise, `r1` is `false` and the result is `()` (if `<exp3>` is absent) or the result of `<exp3>` (if `<exp3>` is present).

## Switch

The switch expression
  `switch <exp0> { (case <pat> <exp>;)+ }`
has type `T` provided:

* `exp0` has type `U`; and
* for each case `case <pat> <exp>` in the sequence `(case <pat> <exp>;)+` :
  * pattern `<pat>` has type `U`; and,
  * expression `<exp>` has type `T`
    (in an environment extended with `<pat>`'s bindings).

The expression evaluates `<exp0>` to a result `r1`.
If `r1` is `trap`, the result is `trap`.
Otherwise, `r1` is some value `v`.
Let `case <pat> <exp>;` be the first case in `(case <pat> <exp>;)+` such that `<pat>` matches `v` with for some bindings of identifiers to values.
Then result of the `switch` is the result of evaluating `<exp>` under those bindings.
If no case has a pattern that matches `v`, the result of the switch is `trap`.

## While

The expression `while <exp1> <exp2>` has type `()` provided:

* `<exp1>` has type `Bool`, and
* `<exp2>` has type `()`.

The expression evaluates `<exp1>` to a result `r1`.
If `r1` is `trap`, the result is `trap`.
Otherwise, `r1` is the value `true` or `false`.
If `r1` is `true`, the result is the result of re-evaluating `while <exp1> <exp2>`.
Otherwise, the result is `()`.

## Loop

The expression `loop <exp>` has type `None` provided `<exp>` has type `()`.

The expression evaluates `<exp>` to a result `r1`.
If `r1` is `trap`, the result is `trap`.
Otherwise, the result is the result of (re-)evaluating `loop <exp1>`.

## Loop While

The expression `loop <exp1> while <exp2>` has type `()` provided:

* `<exp1>` has type `()`, and
* `<exp2>` has type `Bool`.

The expression evaluates `<exp1>` to a result `r1`.
If `r1` is `trap`, the result is `trap`.
Otherwise, evaluation continues with `<exp2>`, producing result `r2`.
If `r2` is `trap` the result is `trap`.
Otherwise, if `r2` is `true`, the result is the result of re-evaluating `loop <exp1> while <exp2>`.
Otherwise, `r2` is false and the result is `()`.

## For

The for expression `for ( <pat> in <exp1> ) <exp2>` has type `()` provided:

* `<exp1>` has type `{ next : () -> ?T; }`;
* pattern `<pat>` has type `T`; and,
* expression `<exp2>` has type `()` (in the environment extended with `<pat>`'s bindings).

The `for`-expression is syntactic sugar for

```bnf
for ( <pat> in <exp1> ) <exp2> :=
  {
    let x = <exp1>;
    label l loop {
      switch (x.next()) {
        case (? <pat>) <exp2>;
        case (null) break l;
      }
    }
  }
```

where `x` is a fresh identifier.

In particular, the `for` loops will trap if evaluation of `<exp1>` traps; as soon as some value of `x.next()` traps or the value of `x.next()` does not match pattern `<pat>`.


_TBR: do we want this semantics? We could, instead, skip values that don't match `<pat>`?_

## Label

The label-expression  `label <id> (: <typ>)? <exp>` has type `T` provided:

* `(: <typ>)?` is absent and `T` is unit; or `(: <typ>)?` is present and `T == <typ>`;
* `<exp>` has type `T` in the static environment extended with `label l : T`.

The result of evaluating `label <id> (: <typ>)? <exp>` is the result of evaluating `<exp>`.

## Labeled loops

If `<exp>` in `label <id> (: <typ>)? <exp>` is a looping construct:

* `while (exp2) <exp1>`,
* `loop <exp1> (while (<exp2>))?`, or
* `for (<pat> in <exp2> <exp1>`

the body, `<exp1>`, of the loop is implicitly enclosed in `label <id_continue> (...)` allowing early continuation of the loop by the evaluation of expression `continue <id>`.

`<id_continue>` is fresh identifier that can only be referenced by `continue <id>`
(through its implicit expansion to `break <id_continue>`).

## Break

The expression `break <id>` is equivalent to `break <id> ()`.

The expression `break <id> <exp>` has type `Any` provided:

* The label `<id>` is declared with type `label <id> : T`.
* `<exp>` has type `T`.

The evaluation of `break <id> <exp>` evaluates exp to some result `r`.
If `r` is `trap`, the result is `trap`.
If `r` is a value `v`, the evaluation abandons the current computation up to dynamically enclosing declaration `label <id> ...` using the value `v` as the result of that labelled expression.

## Continue

The expression `continue <id>` is equivalent to `break <id_continue>`, where
 `<id_continue>` is implicitly declared around the bodies of `<id>`-labelled looping constructs (See Section Labeled Loops).

## Return

The expression `return` is equivalent to `return ()`.

The expression `return <exp>` has type `None` provided:

* `<exp>` has type `T` and
  * `T` is the return type of the nearest enclosing function (with no intervening `async` expression), or
  * `async T` is the type of the nearest enclosing (perhaps implicit) `async` expression (with no intervening function declaration)

The `return` expression exits the corresponding dynamic function invocation or completes the corresponding dynamic async expression with the result of `exp`.

TBR async traps?

## Async

The async expression `async <exp>` has type `async T` provided:

* `<exp>` has type `T`;
* `T` is shared.

Any control-flow label in scope for `async <exp>` is not in scope for `<exp>`. However,
`<exp>` may declare and use its own, local, labels.

The implicit return type in `<exp>` is `T`. That is, the return expression, `<exp0>`, (implicit or explicit) to any enclosed `return <exp0>?` expression, must have type `T`.

Evaluation of `async <exp>` queues a message to evaluate `<exp>` in the nearest enclosing or top-level actor. It immediately returns a promise of type `async T` that can be used to `await` the result of the pending evaluation of `<exp>`.

## Await

The `await` expression `await <exp>` has type `T` provided:

* `<exp>` has type `async T`,
* `T` is shared,
* the `await` is explicitly enclosed by an `async`-expression or appears in the body of a `shared` function.

Expression `await <exp>` evaluates `<exp>` to a result `r`. If `r` is `trap`, evaluation returns `trap`. Otherwise `r` is a promise. If the promise is complete with value `v`, then `await <exp>` evaluates to value `v`.
If the promise is complete with (thrown) error value `e`, then `await <exp>` re-throws the error `e`.
If the `promise` is incomplete, that is, its evaluation is still pending, `await <exp>` suspends evaluation of the neared enclosing `async` or `shared`-function, adding the suspension to the wait-queue of the `promise`. Execution of the suspension is resumed once the promise is completed (if ever).

_WARNING:_ between suspension and resumption of a computation, the state of the enclosing actor may change due to concurrent processing of other incoming actor messages. It is the programmer's responsibility to guard against non-synchronized state changes.


## Throw

The `throw` expression `throw <exp>` has type `None` provided:

* `<exp>` has type `Error`,
* the `throw` is explicitly enclosed by an `async`-expression or appears in the body of a `shared` function.

Expression `throw <exp>` evaluates `<exp>` to a result `r`. If `r` is `trap`, evaluation returns `trap`. Otherwise `r` is an error value `e`. Execution proceeds from the `catch` clause of the nearest enclosing `try <exp> catch <pat> <ex>` whose pattern `<pat>` matches value `e`. If there is no such `try` expression, `e` is stored as the erroneous result of the `async` value of the nearest enclosing `async` expression or `shared` function invocation.

## Try

The `try` expression `try <exp1> catch <pat> <exp2>` has type `T` provided:

* `<exp1>` has type `T`.
* `<pat>` has type `Error` and `<exp2>` has type `T` in the context extended with `<pat>`
* the `try` is explicitly enclosed by an `async`-expression or appears in the body of a `shared` function.

Expression `try <exp1> catch <pat> <exp2>` evaluates `<exp1>` to a result `r`.
If evaluation of  `<exp1>` throws an uncaught error value `e`, the result of the `try` is the result of evaluating `<exp2>` under the bindings determined by the match of `e` against `pat`.

Note: because the `Error` type is opaque, the pattern match cannot fail (typing ensures that `<pat>` is an irrefutable wildcard or identifier pattern).

## Assert

The assert expression `assert <exp>` has type `()` provided `exp` has type `Bool`.

Expression `assert <exp>` evaluates `<exp>` to a result `r`. If `r` is `trap` evaluation returns `trap`. Otherwise `r` is a boolean value `v`. The result of `assert <exp>` is:

* the value `()`, when `v` is `true`; or
* `trap`, when `v` is `false`.

## Type Annotation

The type annotation expression `<exp> : <typ>` has type `T` provided:

* `<typ>` is `T`, and
* `<exp>` has type `T`.

Type annotation may be used to aid the type-checker when it cannot otherwise determine the type of `<exp>` or when one want to constrain the inferred type, `U` of `<exp>` to a less-informative super-type `T` provided `U <: T`.

The result of evaluating `<exp> : <typ>` is the result of evaluating `<exp>`.

Note: type annotations have no-runtime cost and cannot be used to perform the (checked or unchecked) `down-casts` available in other object-oriented languages.

## Declaration Expression

The declaration expression `<dec>` has type `T` provided the declaration `<dec>` has type `T`.

Evaluating the expression `<dec>` proceed by evaluating `<dec>`, returning the result of `<dec>` but discarding the bindings introduced by `<dec>` (if any).

## Parentheses

The parenthesized expression `( <exp> )` has type `T` provided `<exp>` has type `T`.

The result of evaluating `( <exp> : <typ> )` is the result of evaluating `<exp>`.

Note: type annotations have no-runtime cost and are only used to group expression and/or override precedence of language constructs.

# Patterns

```bnf
<pat> ::=                                      patterns
  _                                              wildcard
  <id>                                           variable
  <unop>? <lit>                                  literal
  ( <pat>,* )                                    tuple or brackets
  ? <pat>                                        option
  <pat> : <typ>                                  type annotation
  <pat> or <pat>                                 disjunctive pattern
```

*Patterns* `pat` are used to bind function parameters, declare identifiers and decompose values into their constituent parts in the cases of a `switch` expression.

Matching a pattern against a value may *succeed*, binding the corresponding identifiers in the pattern to their matching values, or *fail*. Thus the result of a match is either a a successful mapping of identifiers to values, or failure.

The consequences of pattern match failure depends on the context of the pattern.

* In a function application or `let`-binding, failure to match the formal argument pattern or `let`-pattern causes a *trap*.
* In a `case` branch of a `switch` expression, failure to match that case's pattern continues with an attempt to match the next case of the switch, trapping only when no such case remains.

## Wildcard pattern

The wildcard pattern `_`  matches a single value without binding its contents to an identifier.

## Identifier pattern

The identifier pattern `<id>` matches a single value and binds it to the identifier `<id>`.

## Literal pattern

The literal pattern `<unop>? <lit>` matches a single value against the constant value of literal `<lit>` and fails if they are not (structurally) equal values.

For integer literals only, the optional `<unop>` determines the sign of the value to match.

## Annotated pattern

The annotated pattern `<pat> : <typ>` matches value of `v` type `<typ>` against the pattern `<pat>`.

`<pat> : <typ>` is *not* a dynamic type test, but is used to constrain the types of identifiers bound in `<pat>`, e.g. in the argument pattern to a function.


## Option pattern

The option `? <pat>` matches a value of option type `? <typ>`.

The match *fails* if the value is `null`. If the value is `? v`, for some value `v`, then the result of matching `? <pat>` is the result of matching `v` against `<pat>`.

Conversely, the `null` literal pattern may be used to test whether a value of option type is the value `null` and not `? v` for some `v`.

## Or pattern

The or pattern `<pat1> or <pat2>` is a disjunctive pattern.

The result of matching `<pat1> or <pat2>` against a value is the result of
matching `<pat1>`, if it succeeds, or the result of matching `<pat2>`, if the first match fails.

(Note, statically, neither `<pat1>` nor `<pat2>` may contain identifier (`<id>`) patterns so a successful match always binds zero identifiers.)

# Declarations

```bnf
<dec> ::=                                                                declaration
  <exp>                                                                    expression
  let <pat> = <exp>                                                        immutable
  var <id> (: <typ>)? = <exp>                                              mutable
  <sort> <id>? =? { <dec-field>;* }                                        object
  shared? func <id>? <typ-params>? <pat> (: <typ>)? =? <exp>               function
  type <id> <typ-params>? = <typ>                                          type
  <sort>? class <id> <typ-params>? <pat> (: <typ>)? =? { <exp-field>;* }   class


```

```bnf
<dec-field> ::=                                object declaration fields
  (public|private)? <dec>                        field
```

## Expression Declaration

The declaration `<exp>` has type `T` provided the expression `<exp>` has type `T` . It declares no bindings.

The declaration `<exp>` evaluates to the result of evaluating `<exp>` (typically for `<exp>`'s side-effect).

TBR

## Let Declaration

The let declaration `<pat> = <exp>` has type `T` and declares the bindings in `<pat>` provided:

* `<exp>` has type `T`.
* `<pat>` has type `T`.

The `<pat> = <exp>` evaluates `<exp>` to a result `r`. If `r` is `trap`, the declaration evaluates to `trap`. If `r` is a value `v` then evaluation proceeds by
matching the value `v` against `<pat>`. If matching fails, then the result is `trap`. Otherwise, the result is `v` and the binding of all identifiers in `<pat>` to their matching values in `v`.

All bindings declared by a let (if any) are *immutable*.

## Var Declaration

The variable declaration `var <id> (: <typ>)? = <exp>` declares a *mutable* variable `<id>` with initial value `<exp>`. The variable's value can be updated by assignment.

The declaration `var <id>` has type `()` provided:

* `<exp>` has type `T`; and
* If the annotation `(:<typ>)?` is present, then `T == <typ>`.

Within the scope of the declaration, `<id>` has type `var T` (see Assignment).

Evaluation of `var <id> (: <typ>)? = <exp>` proceeds by evaluating `<exp>` to a result `r`. If `r` is `trap`, the declaration evaluates to `trap`. Otherwise, the
`r` is some value `v` that determines the initial value of mutable variable `<id>`.
The result of the declaration is `()` and
`<id>` is bound to a fresh location that contains `v`.

## Type Declaration

The declaration `type <id> <typ-params>? = <typ>` declares a new type constructor `<id>`, with optional type parameters `<typ-params>` and definition `<typ>`.

The declaration `type C < X0<:T0>, ..., Xn <: Tn > = U` is well-formed provided:

* type parameters `X0`, ..., `Xn` are distinct, and
* assuming the constraints `X0 <: T0`, ..., `Xn <: Tn`:
  * constraints `T0`, ..., `Tn` are well-formed.
  * definition `U` is well-formed.

In scope of the declaration  `type C < X0<:T0>, ..., Xn <: Tn > = U`, any  well-formed type `C < U0, ..., Un>` is equivalent to its expansion
`U [ U0/X0, ..., Un/Xn ]`.  Distinct type expressions that expand to identical types are inter-changeable, regardless of any distinction between type constructor names. In short, the equivalence between types is structural, not nominal.

## Object Declaration

Declaration `<sort> <id>? =? { <exp-field>;* }` declares an object with optional identifier `<id>` and zero or more fields `<exp_field>;*`.
Fields can be declared with `public` or `private` visibility; if the visibility is omitted, it defaults to `private`.

The qualifier `<sort>` (one of 'actor', 'module' or 'object') specifies the *sort* of the object's type. The sort imposes restrictions on the types of the public object fields.

Let `T = sort { [var0] id0 : T0, ... , [varn] idn : T0 }` denote the type of the object.
Let `<dec>;*` be the sequence of declarations in `<exp_field>;*`.
The object declaration has type `T` provided that:

1. type `T` is well-formed for sort `sort`, and
2. under the assumption that `<id> : T`,
   * the sequence of declarations `<dec>;*` has type `Any` and declares the disjoint sets of private and public identifiers, `Id_private` and `Id_public` respectively,
     with types `T(id)` for `id` in `Id == Id_private union Id_public`, and
   * `{ id0, ..., idn } == Id_public`, and
   * for all `i in 0 <= i <= n`, `[vari] Ti == T(idi)`.

Note that requirement 1. imposes further constraints on the field types of `T`.
In particular:

* if the sort is `actor` then all public fields must be non-`var` (immutable)     `shared` functions (the public interface of an actor can only provide asynchronous messaging via shared functions).

Evaluation of `(object|actor)? <id>? =? { <exp-field>;* }` proceeds by
evaluating the declarations in `<dec>;*`. If the evaluation of `<dec>;*` traps, so does the object declaration.
Otherwise, `<dec>;*` produces a set of bindings for identifiers in `Id`.
let `v0`, ..., `vn` be the values or locations bound to identifiers `<id0>`, ..., `<idn>`.
The result of the object declaration is the object `v == sort { <id0> = v1, ..., <idn> = vn}`.

If `<id>?` is present, the declaration binds `<id>` to `v`. Otherwise, it produces the empty set of bindings.

_TBR do we actually propagate trapping of actor creation?_

## Function Declaration

The function declaration  `shared? func <id>? <typ-params>? <pat> (: <typ>)? =? <exp>` is syntactic sugar for
a `let` declaration of a function expression. That is:

```bnf
shared? func <id> <typ-params>? <pat> (: <typ>)? =? <exp> :=
  let <id> = shared? func <id> <typ-params>? <pat> (: <typ>)? =? <exp>
```

where `<pat>` is `<id>` when `<id>?` is present and `<pat>` is `_` otherwise.

Named function definitions are recursive.

## Class declarations

The declaration `<sort>? class <id> <typ-params>? <pat> (: <typ>)? =? <id_this>? { <exp-field>;* }` is sugar for pair of a type and function declaration:

```bnf
<sort>? class <id> <typ-params>? <pat> (: <typ>)? =? <id_this>? { <dec-field>;* } :=
  type <id> <typ-params> = <sort> { <typ-field>;* };
  func <id> <typ-params>? <pat> : <id> <typ-args>  = <sort> <id_this>? { <dec-field>;* }
```

where:

* `<typ-args>?` is the sequence of type identifiers bound by `<typ-params>?` (if any), and
* `<typ-field>;*` is the set of public field types inferred from `<dec-field;*>`.
* `<id_this>?` is the optional `this` parameter of the object instance.


## Declaration Fields

```bnf
<dec-field> ::=                                object expression fields
  (public|private)? <dec>                        field
```

Declaration fields declare the fields of actors and objects.
They are just declarations, prefixed by an optional visibility qualifier `public` or  `private`; if omitted, visibility defaults to `private`.

Any identifier bound by a `public` declaration appears in the type of enclosing object and is accessible via the dot notation.

An identifier bound by a `private` declaration is excluded form the type of the enclosing object and inaccessible via the dot notation.

# Sequence of Declarations

A sequence of declarations `<dec>;*` occurring in a block, a program or the `exp-field;*` sequence of an object declaration has type `T`
provided

* `<dec>;*` is empty and `T == ()`; or
* `<dec>;*` is non-empty and:
  * all value identifiers bound by `<dec>;*` are distinct, and
  * all type identifiers bound by `<dec>;*` are distinct, and
  * under the assumption that each value identifier `<id>` in `decs;*` has type `var_id? Tid`,
    and assuming the type definitions in `decs;*`:
    * each declaration in `<dec>;*` is well-typed, and
    * each value identifier `<id>` in bindings produced by `<dec>;*` has type `var_id? Tid`, and
    * the last declaration in `<dec>;*` has type `T`.

Declarations in `<dec>;*` are evaluated sequentially. The first declaration that traps causes the entire sequence to trap.
Otherwise, the result of the declaration is the value of the last declaration in `<dec>;*`. In addition, the set of value bindings defined by  `<dec>;*` is
the union of the bindings introduced by each declaration in `<dec>;*`.

It is a compile-time error if any declaration in `<dec>;*` might require the value of an identifier declared in `<dec>;*`
before that identifier's declaration has been evaluated. Such *use-before-define* errors are detected by a simple,
conservative static analysis not described here.

# Programs

```bnf
<prog> ::=
 <dec>;*

```

A program `<prog>` is a sequence of declarations `<dec>;*` that ends with an optional actor declaration. The actor declaration determines the main actor, if any, of the program.

All type and value declarations within `<prog>` are mutually-recursive.
