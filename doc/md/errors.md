# エラーと Option

Motoko では、エラー値を表現し処理するための方法が主に 3 つあります。

- Option 値（_何らかの_ エラーを示す、情報を持たない `null` 値を含む）

- `Result` のバリアント（エラーに関する詳細な情報を提供する `#err 値` の記述を含む）

- `Error` 値（非同期コンテキストでは、例外処理のようにスロー（throw）したりキャッチ（catch）したりすることができ、数値コードとメッセージを含む）

## API の例

Todo アプリケーションの API を構築していると想定し、ユーザーが Todo の 1 つに **Done** という印を付ける関数を公開したいとします。 問題をシンプルにするために、`TodoId` を受け取り、Todo を開いてから何秒経ったかを表す `Int` を返すことにします。 また、自分自身の Actor で実行していると仮定し、非同期の値を返すことにします。 問題が一切起きないとすると、次のような API になります。

```motoko no-repl
func markDone(id : TodoId) : async Int
```

参照のため、このドキュメント内で使用する全ての型とヘルパー関数の全体記述を示します。

```motoko no-repl file=./examples/todo-error.mo#L1-L6

```

```motoko no-repl file=./examples/todo-error.mo#L10-L37

```

## 問題が起こる場合

ここで、Todo に完了の印をつける処理が失敗する条件があることに気がつきました。

- `id` が存在しない Todo に紐づけられている可能性がある

- Todo にすでに完了の印がついている可能性がある

これから Motoko でこれらのエラーを取り扱う様々な方法について示し、コードを徐々に改善していきます。

## どのようなエラー型が良いか

### どうすべき _ではない_ のか

エラーを報告する簡単で _良くない_ 方法の一つは、_番兵 （Sentinel）_ を使用することです。例えば、 `markDone` 関数において `-1` という値を使用して、何かが失敗したことを通知することにします。その場合、呼び出し側は戻り値をこの特別な値と照らし合わせてエラーを報告しなければなりません。しかし、エラー状態をチェックせずに、その値を使ってその後の処理を続けることはあまりにも簡単です。 これは、エラーの検出を遅らせたり見逃したりすることにつながるので、必ず避けるべきです。

定義：

```motoko no-repl file=./examples/todo-error.mo#L38-L47

```

呼び出し側：

```motoko no-repl file=./examples/todo-error.mo#L108-L115

```

### 可能であれば、例外よりも Option/Result を優先する

Motoko では、エラーを通知する方法として `Option` や `Result` を使用することが推奨されています。 これらは同期・非同期のどちらのコンテキストでも動作し、API をより安全に使用することができます （成功と同様にエラーも考慮するようにクライアントに促すことができます）。 例外は、予期しないエラー状態を通知するためにのみ使用されるべきです。

### Option によるエラー通知

`A` 型の値を返すかそうでなければエラー通知を行いたい関数は、 _Option_ 型の `?A` の値を返し、 `null` 値を使用してエラーを指定することができます。 今の例では、`markDone` 関数が `async ?Seconds` を返すことを意味します。

以下は、 `markDone` 関数の例です。

定義：

```motoko no-repl file=./examples/todo-error.mo#L49-L58

```

呼び出し側：

```motoko no-repl file=./examples/todo-error.mo#L117-L126

```

この方法の主な欠点は、起こりうるすべてのエラーを、情報を持たない一つの `null` 値にひとまとめにしてしまうことです。 呼び出し側は `Todo` を完了させることに失敗した理由に興味があるかもしれませんが、その情報は失われています。つまり、ユーザーには `"何かがうまくいかなかった"` としか伝えられません。 エラーを知らせるために Option 値を返すのは、失敗の原因が 1 つだけで、その原因が呼び出し側で容易に判断できる場合だけにすべきです。 この良い使用例のひとつは、HashMap の参照に失敗した場合です。

### `Result` 型によるエラーリポート

エラーを知らせるために Option 型を使用することの欠点を解決するために、今度はより多機能な `Result` 型を見てみましょう。 Option は組み込みの型ですが、 `Result` は以下のようにバリアント型として定義されています。

```motoko no-repl
type Result<Ok, Err> = { #ok : Ok; #err : Err }
```

2 つ目の型引数である `Err` により、`Result` 型ではエラーを記述するために使用する型を選択することができます。 そこで、`markDone` 関数がエラーを通知するために使用する `TodoError` 型を定義することにします。

```motoko no-repl file=./examples/todo-error.mo#L60-L60

```

これを用いて `markDone` の 3 つ目のバージョンを書きます。

定義：

```motoko no-repl file=./examples/todo-error.mo#L62-L76

```

呼び出し側：

```motoko no-repl file=./examples/todo-error.mo#L128-L141

```

ご覧の通り、ユーザーに役立つエラーメッセージを表示することができるようになりました。

## Option/Result を使用する

`Option` と `Results` は、（あなたがいたる所で例外処理を行うようなプログラミング言語から来た場合は特に）エラーについて異なる考え方をすることになります。 この章では、`Option` と `Results` を作成、再構築、変換、結合するさまざまな方法を見ていきます。

### パターンマッチング

最初の、そして最も一般的な `Option` と `Result` の使用場面はパターンマッチングです。 `?Text` 型の値があるとき、`switch` キーワードを使って潜在する `Text` の値にアクセスすることができます。

```motoko no-repl file=./examples/error-examples.mo#L3-L10

```

ここで理解すべき重要なことは、Motoko は Option の値にアクセスするときは必ず、値が見つからない場合を考慮させるということです。

`Result` の場合もパターンマッチングを使うことができます。ただし、`#err` の場合は、（単なる `null` ではなく）情報を持つ値も取得できるという違いがあります。

```motoko no-repl file=./examples/error-examples.mo#L12-L19

```

### 高階関数

パターンマッチングは、複数の Option 値を扱う場合は特に、退屈で冗長になることがあります。 [Motoko 標準ライブラリ](https://github.com/dfinity/motoko-base) は、`Optional` と `Result` モジュールの高階関数群を公開することで、エラー処理を人間工学的に改善します。

### Option と Result の相互変換

Option と Result の間を行ったり来たりしたいことがあります。 例えば HashMap の参照に失敗すると `null` が返され、それはそれで良いのですが、呼び出し元はより多くのコンテキストを持っていて、その検索の失敗を意味のある `Result` に変換できるかもしれません。 他には、`Result` が提供する追加情報は必要なく、単にすべての `#err` ケースを `null` に変換したいという場面もあります。 このような場合のために、 [Motoko 標準ライブラリ](https://github.com/dfinity/motoko-base) では `Result` モジュールに `fromOption` と `toOption` という関数を用意しています。

## 非同期エラー

Motoko でエラーを処理する最後の方法は、非同期の `Error` 処理を使うことです。これは他の言語でおなじみの例外処理に制限を設けたものです。 他の言語の例外処理とは異なり、Motoko の _エラー_ の値は `shared` 関数または `async` 式の本体といった非同期コンテキストでのみ、スロー（throw）とキャッチ（catch）を行うことができます。非 `shared` 関数は構造化されたエラー処理を行うことができません。 つまり、`throw` でエラー値を投げて `shared` 関数を終了したり、`try` で別の Actor 上の `shared` 関数を呼び出して失敗を `Error` 型で `catch` することはできますが、これらのエラー処理を非同期のコンテキスト以外の通常のコードで使用することはできません。

非同期の `Error` は一般的に、回復できないような予期しない失敗を知らせる目的で、かつあなたの API を多くの人が利用しない場合にのみ使用されるべきです。もし失敗が呼び出し側で処理されるべきものであれば、代わりに `Result` を返すことで、シグネチャ（signature）でそれを明示する必要があります。完全を期すために、例外を含む `markDone` の例を以下に示します。

定義：

```motoko no-repl file=./examples/todo-error.mo#L78-L92

```

呼び出し側：

```motoko no-repl file=./examples/todo-error.mo#L143-L150

```

<!--
# Errors and Options

There are three primary ways to represent and handle errors values in Motoko:

-   Option values (with a non-informative `null` indicated *some* error);

-   `Result` variants (with a descriptive `#err value` providing more information about the error); and

-   `Error` values (that, in an asynchronous context, can be thrown and caught - similar to exceptions - and contain a numeric code and message).

## Our Example API

Let’s assume we’re building an API for a Todo application and want to expose a function that lets a user mark one of their Todo’s as **Done**. To keep it simple we’ll accept a `TodoId` and return an `Int` that represents how many seconds the Todo has been open. We’re also assuming we’re running in our own actor so we return an async value. If nothing would ever go wrong that would leave us with the following API:

``` motoko no-repl
func markDone(id : TodoId) : async Int
```

The full definition of all types and helpers we’ll use in this document is included for reference:

``` motoko no-repl file=./examples/todo-error.mo#L1-L6
```

``` motoko no-repl file=./examples/todo-error.mo#L10-L37
```

## When things go wrong

We now realize that there are conditions under which marking a Todo as done fails.

-   The `id` could reference a non-existing Todo

-   The Todo might already be marked as done

We’ll now talk about the different ways to communicate these errors in Motoko and slowly improve our solution.

## What error type to prefer

### How *not* to do things

One particularly easy and *bad* way of reporting errors is through the use of a *sentinel* value. For example, for our `markDone` function we might decide to use the value `-1` to signal that something failed. The callsite then has to check the return value against this special value and report the error. But it’s way too easy to not check for that error condition and continue to work with that value in our code. This can lead to delayed or even missing error detection and is strongly discouraged.

Definition:

``` motoko no-repl file=./examples/todo-error.mo#L38-L47
```

Callsite:

``` motoko no-repl file=./examples/todo-error.mo#L108-L115
```

### Prefer Option/Result over Exceptions where possible

Using `Option` or `Result` is the preferred way of signaling errors in Motoko. They work in both synchronous and asynchronous contexts and make your APIs safer to use (by encouraging clients to consider the error cases as well as the success cases. Exceptions should only be used to signal unexpected error states.

### Error reporting with Option

A function that wants to return a value of type `A` or signal an error can return a value of *option* type `?A` and use the `null` value to designate the error. In our example this means having our `markDone` function return an `async ?Seconds`.

Here’s what that looks like for our `markDone` function:

Definition:

``` motoko no-repl file=./examples/todo-error.mo#L49-L58
```

Callsite:

``` motoko no-repl file=./examples/todo-error.mo#L117-L126
```

The main drawback of this approach is that it conflates all possible errors with a single, non-informative `null` value. Our callsite might be interested in why marking a `Todo` as done has failed, but that information is lost by then, which means we can only tell the user that `"Something went wrong."`. Returning option values to signal errors should only be used if there just one possible reason for the failure, and that reason can be easily determined at the callsite. One example of a good usecase for this is a HashMap lookup failing.

### Error reporting with `Result` types

To address the shortcomings of using option types to signal errors we’ll now look at the richer `Result` type. While options are a built-in type, the `Result` is defined as a variant type like so:

``` motoko no-repl
type Result<Ok, Err> = { #ok : Ok; #err : Err }
```

Because of the second type parameter, `Err`, the `Result` type lets us select the type we use to describe errors. So we’ll define a `TodoError` type our `markDone` function will use to signal errors.

``` motoko no-repl file=./examples/todo-error.mo#L60-L60
```

This lets us now write the third version of `markDone`:

Definition:

``` motoko no-repl file=./examples/todo-error.mo#L62-L76
```

Callsite:

``` motoko no-repl file=./examples/todo-error.mo#L128-L141
```

And as we can see we can now give the user a useful error message.

## Working with Option/Result

`Option`s and `Results`s are a different way of thinking about errors, especially if you come from a language with pervasive exceptions. In this chapter we’ll look at the different ways to create, destructure, convert, and combine `Option`s and `Results` in different ways.

### Pattern matching

The first and most common way of working with `Option` and `Result` is to use 'pattern matching'. If we have a value of type `?Text` we can use the `switch` keyword to access the potential `Text` contents:

``` motoko no-repl file=./examples/error-examples.mo#L3-L10
```

The important thing to understand here is that Motoko does not let you access the optional value without also considering the case that it is missing.

In the case of a `Result` we can also use pattern matching, with the difference that we also get an informative value (not just `null`) in the `#err` case.

``` motoko no-repl file=./examples/error-examples.mo#L12-L19
```

### Higher-Order functions

Pattern matching can become tedious and verbose, especially when dealing with multiple optional values. The [base](https://github.com/dfinity/motoko-base) library exposes a collection of higher-order functions from the `Optional` and `Result` modules to improve the ergonomics of error handling.

### Converting back and forth between Option/Result

Sometimes you’ll want to move between Options and Results. A Hashmap lookup returns `null` on failure and that’s fine, but maybe the caller has more context and can turn that lookup failure into a meaningful `Result`. At other times you don’t need the additional information a `Result` provides and just want to convert all `#err` cases into `null`. For these situations [base](https://github.com/dfinity/motoko-base) provides the `fromOption` and `toOption` functions in the `Result` module.

## Asynchronous Errors

The last way of dealing with errors in Motoko is to use asynchronous `Error` handling, a restricted form of the exception handling familiar from other languages. Unlike the exceptions of other languages, Motoko *errors* values, can only be thrown and caught in asynchronous contexts, typically the body of a `shared` function or `async` expression. Non-`shared` functions cannot employ structured error handling. This means you can exit a shared function by `throw`ing an `Error` value and `try` some code calling a shared function on another actor, `catch`ing its failure as a result of type `Error`, but you can’t use these error handling constructs in regular code, outside of an asynchronous context.

Asynchronous `Error`s should generally only be used to signal unexpected failures that you cannot recover from, and that you don’t expect many consumers of your API to handle. If a failure should be handled by your caller you should make it explicit in your signature by returning a `Result` instead. For completeness here is the `markDone` example with exceptions:

Definition:

``` motoko no-repl file=./examples/todo-error.mo#L78-L92
```

Callsite:

``` motoko no-repl file=./examples/todo-error.mo#L143-L150
```

-->
