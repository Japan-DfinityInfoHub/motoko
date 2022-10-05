# モジュールとインポート

この章では、`module` と `import` キーワードを使用するさまざまなシナリオの例を紹介します。

これらのキーワードがどのように使われるかを知るために、いくつかのサンプルコードを見てみましょう。

## Motoko 標準ライブラリからのインポート

最も一般的なインポートの使用場面の 1 つは、このガイドの例やサンプルリポジトリの Motoko プロジェクトやチュートリアルで見られるように、Motoko 標準ライブラリからモジュールをインポートすることです。 標準ライブラリからモジュールをインポートすることで、同じようなものを最初から書くのではなく、それらのモジュールで定義された値、関数、型を再利用することができます。

以下の 2 行は `Array` と `Result` モジュールから関数をインポートしています。

```motoko
import Array "mo:base/Array";
import Result "mo:base/Result";
```

import 宣言には、Motoko モジュールであることを示す `mo:` という接頭辞が含まれており、宣言には `.mo` というファイルの拡張子がないことに注意してください。

上記の例では、識別子を使ってモジュールを一括してインポートしていますが、 以下のようなオブジェクトパターンの構文を用いることで、サブセットをモジュールから選択的にインポートすることもできます。

```motoko
import { map; find; foldLeft = fold } = "mo:base/Array";
```

この例では、関数 `map` と `find` はそのままインポートされ、関数 `foldLeft` は `fold` にリネームされます。

## ローカルファイルのインポート

Motoko でプログラムを書くためのもう一つの一般的なアプローチは、ソースコードを異なるモジュールに分割することです。 例えば、以下のようなモデルでアプリケーションを設計するとします。

- ステートを変更する Actor と関数を格納する `main.mo` ファイル。

- カスタムの型定義を格納する `types.mo` ファイル。

- Actor の外で動作する関数を格納する `utils.mo` ファイル。

このシナリオでは、3 つのファイルを同じディレクトリに置き、ローカルインポートを使って、必要な場所で関数を利用できるようにすると良いでしょう。

例えば `main.mo` には、同じディレクトリにあるモジュールを参照するために、以下のような行が含まれています。

```motoko no-repl
import Types "types";
import Utils "utils";
```

これらの行は Motoko ライブラリではなくローカルプロジェクトのモジュールをインポートしているので、これらのインポート宣言は `mo:` 接頭辞を使用しません。

この例では、`types.mo` と `utils.mo` のファイルが `main.mo` ファイルと同じディレクトリに置かれています。 繰り返しになりますが、インポートは `.mo` 接頭辞を使用しません。

## 他のパッケージやディレクトリからのインポート

他のパッケージやローカルディレクトリ以外のディレクトリからモジュールをインポートすることもできます。

例えば、以下は依存関係にある `redraw` パッケージからモジュールをインポートしている例です。

```motoko no-repl
import Render "mo:redraw/Render";
import Mono5x5 "mo:redraw/glyph/Mono5x5";
```

プロジェクトの依存関係は、パッケージマネージャである Vessel を使うか、プロジェクトの設定ファイルである `dfx.json` で定義することができます。

この例では、`Render` モジュールは `redraw` パッケージのソースコードのデフォルトの場所にあり、`Mono5x5` モジュールは `redraw` パッケージのサブディレクトリである `glyph` に入っています。

## Actor クラスのインポート

モジュールのインポートは、通常ローカルの関数や値のライブラリをインポートするために使用されますが、Actor クラスをインポートするために使用することもできます。 インポートされたファイルが名前付きの Actor クラスで構成されている場合、インポートされたフィールドのクライアントから Actor クラスを含むモジュールを見ることができます。

モジュールには 2 つのコンポーネントがあり、両方とも Actor クラスの名前をとって命名されています。

- クラスのインタフェースを記述する型定義。

- クラスのパラメータを引数に取り、非同期でクラスの新しいインスタンスを返す非同期関数。

例えば、Motoko の Actor は [Actor と async データ](actors-async.md#actor-classes-generalize-actors) で述べた `Counter` クラスを次のようにインポートしてインスタンス化することができます。

`Counters.mo`:

```motoko name=Counters file=./examples/Counters.mo

```

`CountToTen.mo`:

```motoko include=Counters file=./examples/CountToTen.mo

```

`Counters.Counter(1)` の呼び出しは、ネットワーク上に新しいカウンタをインストールします。インストールは非同期なので、呼び出し元は結果を `await` しなければなりません。

型注釈 `: Counters.Counter` はここでは冗長です。Actor クラスの型が必要なときに利用できることを示す目的で記載しています。

## 他の Canister スマートコントラクトからのインポート

上記の Motoko モジュールをインポートする例に加え、`mo:` の代わりに `canister:` という接頭辞を用いることで、Canister スマートコントラクトから Actor とその共有（shared）関数 をインポートすることもできます。

:::note

Motoko ライブラリとは異なり、インポートされた Canister は、その Canister スマートコントラクト用の Candid インターフェースを発行する他の Internet Computer 言語（例えば Rust）で実装することが可能です。それは Motoko の古いバージョンや新しいバージョンである可能性もあります。

:::

例えば、以下の 3 つの Canister を生成するプロジェクトがあるとします。

- BigMap（Rust で実装）

- Connectd（Motoko で実装）

- LinkedUp（Motoko で実装）

これら 3 つの Canister はプロジェクトの設定ファイルである `dfx.json` で宣言され、`dfx build` を実行することでコンパイルされます。

次に、`BigMap` と `Connectd` Canister を Motoko LinkedUp Actor 内の Actor として以下のようにインポートすることができます。

```motoko no-repl
import BigMap "canister:BigMap";
import Connectd "canister:connectd";
```

Canister をインポートするとき、インポートされた Canister の型は **Motoko モジュール** ではなく **Motoko Actor** に対応することに注意することが重要です。 この区別は、データ構造がどのように型付けされるかに影響を与えます。

インポートされた Canister の Actor では、型は Motoko からではなく、Canister 用の Candid ファイル（_プロジェクト名_.did ファイル）から与えられます。

Motoko の Actor 型から Candid のサービス（service）型への変換は、ほとんどの場合には 1 対 1 対応ですが、同じ Candid 型にマッピングするいくつかの異なる Motoko 型が存在します。例えば、Motoko の `Nat32` と `Char` 型は両方とも Candid の `nat32` 型としてエクスポートされますが、`nat32` は `Char` ではなく Motoko の `Nat32` として標準的（canonical）にインポートされます。

したがって、インポートされた Canister 関数の型は、それを実装している元の Motoko コードの型と異なる場合があります。 例えば、Motoko の関数の実装で `shared Nat32 -> async Char` という型があった場合、エクスポートされた Candid 型は `(nat32) -> (nat32)` になりますが、この Candid 型からインポートされた Motoko の型は実際には（正しいのですがおそらく予想に反する）`shared Nat32 -> async Nat32` になります。

## インポートモジュールの命名

上記の例のようにインポートモジュールをモジュール名で識別するのが最も一般的な慣習ですが、必ずしもそうする必要はありません。 例えば、名前の衝突を避けるため、あるいは命名を簡単にするために、異なる名前を使用したい場合があります。

標準ライブラリから `List` モジュールをインポートする際に、架空の `collections` パッケージの別の `List` ライブラリと名前が衝突しないように、異なる名前を使用する例を以下に示します。

```motoko no-repl
import List "mo:base/List:";
import Sequence "mo:collections/List";
import L "mo:base/List";
```

<!--

# Modules and imports

This section provides examples of different scenarios for using the `module` and `import` keywords.

To illustrate how these keywords are used, let’s step through some sample code.

## Importing from the Motoko base library

One of the most common import scenarios is one that you see illustrated in the examples in this guide, in the Motoko projects in the examples repository, and in the tutorials involves importing modules from the Motoko base library. Importing modules from the base library enables you to re-use the values, functions and types defined in those modules rather than writing similar ones from scratch.

The following two lines import functions from the `Array` and `Result` modules:

``` motoko
import Array "mo:base/Array";
import Result "mo:base/Result";
```

Notice that the import declaration includes the `mo:` prefix to identify the module as a Motoko module and that the declaration does not include the `.mo` file type extension.

Above example uses an identifier pattern to import modules wholesale, but you can also selectively import a subset of symbols from a module by resorting to the object pattern syntax:

``` motoko
import { map; find; foldLeft = fold } = "mo:base/Array";
```

In this example, the functions `map` and `find` are imported unaltered, while the `foldLeft` function is renamed to `fold`.

## Importing local files

Another common approach to writing programs in Motoko involves splitting up the source code into different modules. For example, you might design an application to use the following model:

-   a `main.mo` file to contain the actor and functions that change state.

-   a `types.mo` file for all of your custom type definitions.

-   a `utils.mo` file for functions that do work outside of the actor.

In this scenario, you might place all three files in the same directory and use a local import to make the functions available where they are needed.

For example, the `main.mo` contains the following lines to reference the modules in the same directory:

``` motoko no-repl
import Types "types";
import Utils "utils";
```

Because these lines import modules from the local project instead of the Motoko library, these import declarations don’t use the `mo:` prefix.

In this example, both the `types.mo` and `utils.mo` files are in the same directory as the `main.mo` file. Once again, import does not use the `.mo` file suffix.

## Importing from another package or directory

You can also import modules from other packages or from directories other than the local directory.

For example, the following lines import modules from a `redraw` package that is defined as a dependency:

``` motoko no-repl
import Render "mo:redraw/Render";
import Mono5x5 "mo:redraw/glyph/Mono5x5";
```

You can define dependencies for a project using the Vessel package manager or in the project `dfx.json` configuration file.

In this example, the `Render` module is in the default location for source code in the `redraw` package and the `Mono5x5` module is in a `redraw` package subdirectory called `glyph`.

## Importing actor classes

While module imports are typically used to import libraries of local functions and values, they can also be used to import actor classes. When an imported file consists of a named actor class, the client of the imported field sees a module containing the actor class.

This module has two components, both named after the actor class:

-   a type definition, describing the interface of the class, and

-   an asynchronous function, that takes the class parameters as arguments an asynchronously returns a fresh instance of the class.

For example, a Motoko actor can import and instantiate the `Counter` class described in [Actors and async data](actors-async.md#actor-classes-generalize-actors) as follows:

`Counters.mo`:

``` motoko name=Counters file=./examples/Counters.mo
```

`CountToTen.mo`:

``` motoko include=Counters file=./examples/CountToTen.mo
```

The call to `Counters.Counter(1)` installs a fresh counter on the network. Installation is asynchronous, so the caller must `await` the result.

The type annotation `: Counters.Counter` is redundant here. It’s included only to illustrate that the type of the actor class is available when required.

## Importing from another canister smart contract

In addition to the examples above that import Motoko modules, you can also import actors (and their shared functions) from canister smart constracts by using the `canister:` prefix in place of the `mo:` prefix.

:::note

Unlike a Motoko library, an imported canister can be implemented in any other Internet Computer language that emits Candid interfaces for its canister smart contracts (for instance Rust). It could even be an older or newer version of Motoko.

:::

For example, you might have a project that produces the following three canisters:

-   BigMap (implemented in Rust)

-   Connectd (implemented in Motoko)

-   LinkedUp (implemented in Motoko)

These three canisters are declared in the project’s `dfx.json` configuration file and compiled by running `dfx build`.

You can then use the following lines to import the `BigMap` and `Connectd` canisters as actors in the Motoko LinkedUp actor:

``` motoko no-repl
import BigMap "canister:BigMap";
import Connectd "canister:connectd";
```

When importing canisters, it is important to note that the type for the imported canister corresponds to a **Motoko actor** instead of a **Motoko module**. This distinction can affect how some data structures are typed.

For the imported canister actor, types are derived from the Candid file — the *project-name*.did file — for the canister rather than from Motoko itself.

The translation from Motoko actor type to Candid service type is mostly, but not entirely, one-to-one, and there are some distinct Motoko types that map to the same Candid type. For example, the Motoko `Nat32` and `Char` types both exported as Candid type `nat32`, but `nat32` is canonically imported as Motoko `Nat32`, not `Char`.

The type of an imported canister function, therefore, might differ from the type of the original Motoko code that implements it. For example, if the Motoko function had type `shared Nat32 -> async Char` in the implementation, its exported Candid type would be `(nat32) -> (nat32)` but the Motoko type imported from this Candid type will actually be the correct—but perhaps unexpected—type `shared Nat32 -> async Nat32`.

## Naming imported modules

Although the most common convention is to identify imported modules by the module name as illustrated in the examples above, there’s no requirement for you to do so. For example, you might want to use different names to avoid naming conflicts or to simplify the naming scheme.

The following examples illustrate different names you might use when importing the `List` base library module, avoiding a clash with another `List` library from a fictional `collections` package.

``` motoko no-repl
import List "mo:base/List:";
import Sequence "mo:collections/List";
import L "mo:base/List";
```

-->
