# ステーブル（Stable）変数とアップグレード方法

Internet Computer の重要な特徴の一つは、従来のデータベースとは異なり、WebAssembly のメモリとグローバルを使用することで、Canister のスマートコントラクトのステートを永続化できることです。これは、明示的なユーザーの指示なしに、Canister のステート全体が各メッセージの前に魔法のように復元され、後に保存されることを意味します。この自動的でユーザーに影響を与えない（user-transparent）ステートの保存は、_直交永続性（orthogonal persistence）_ と呼ばれています。

直交永続性は便利ですが、Canister のコードを更新する際に課題が生じます。 Canister のステートを明示的に表現することなく、引退した Canister から新たな Canister にアプリケーションのデータをどのように移行すればよいのでしょうか。

データを失うことなくアップグレードに対応するには、Canister の重要なデータをアップグレード後の Canister に _移行_ するための新しい機能が必要です。 たとえば、ユーザ登録を行う Canister があったとし、問題を修正したり新たな機能を追加したりするために新しいバージョンをデプロイしたい場合、すでに登録されているユーザ情報がアップグレード処理後に失われないようにする必要があります。

Internet Computer の永続化モデルにより、Canister はこのようなデータを専用の _ステーブルメモリ（stable memory）_ に保存し、復元することができます。ステーブルメモリは通常の Canister メモリとは異なり、アップグレードしても保持されるので、Canister はデータを一括して新たな Canister に転送することができます。

Motoko で書かれたアプリケーションでは、Internet Computer のステーブルメモリを活用したステート保持のための高レベルなサポートが提供されます。この高レベルの機能は _ステーブルストレージ（stable storage）_ と呼ばれ、アプリケーションのデータと、コードを生成するために使用される Motoko コンパイラの両方への変更に対応するように設計されています。

ステーブルストレージの活用はアプリケーションプログラマであるあなた次第であり、アップグレード後も保持したいデータを予測し、指示することが必要です。 アプリケーションによって、永続化するデータは、ある Actor のステートの一部かすべて、または一切ない可能性もあります。

## ステーブル変数の宣言

Actor では、変数宣言の修飾子として `stable` キーワードを使用することで、変数をステーブルストレージ（Internet Computer ステーブルメモリ）に登録することができます。

より正確には、Actor 内のすべての `let` と `var` の変数宣言において、その変数が `stable` と `flexible` のどちらであるかを指定することができます。 修飾子を指定しなかった場合、変数はデフォルトで `flexible` として宣言されます。

以下に、カウンタの値を保持したままアップグレードすることができる、ステーブルなカウンタを宣言するための簡単な例を示します。

```motoko file=./examples/StableCounter.mo

```

`stable` または `flexible` 修飾子は、 **Actor フィールド** の `let` および `var` 宣言にのみ使用することができます。これらの修飾子は、プログラム中の他の場所では使用できません。

## 型付け（Typing）

コンパイラは、アップグレード後のプログラムにおいて、ステーブル変数が互換性と意味を持つことを保証しなければならないため、ステーブルなステートには以下の型制約が適用されます。

- すべての `stable` 変数は _stable_ 型を持たなければなりません。

ここで、`var` 修飾子を無視したときに型が _shared_ であれば、_stable_ 型となります。

したがって、stable 型と shared 型の唯一の違いは、前者はミュータブルな更新（mutation）をサポートしていることです。 shared 型と同様に、stable 型はローカル関数とローカル関数から構築された構造体（オブジェクトなど）を除外した一次データ（first-order data）に限定されます。 このように関数を除外する必要があるのは、データとコードの両方からなる関数値の意味は、アップグレードの際に容易に保存できないからです。一方、プレーンデータの意味は、ミュータブルかどうかにかかわらず保存可能です。

:::note

一般的に、オブジェクト型はローカル関数を含むことができるため、ステーブルではありません。 しかし、ステーブルなデータのプレーンレコードは、オブジェクト型の特別なケースとしてステーブル型になります。 さらに、Actor や shared 関数への参照もステーブルであるため、アップグレードをまたいでその値を保持することができます。 たとえば、Service を参照している Actor や shared 関数のコールバックを記録するステートを保持することができます。

:::

## ステーブル変数のアップグレード方法

Canister を最初にコンパイルしてデプロイするとき、Actor 内のすべてのフレキシブル（flexible）変数とステーブル変数が順番に初期化されます。 `upgrade` モードを使用して Canister をデプロイすると、Actor の前のバージョンに存在したすべてのステーブル変数が、古い値で事前に初期化されます。 ステーブル変数が以前の値で初期化された後、残りのフレキシブル変数と新しく追加されたステーブル変数が順番に初期化されます。

## プリアップグレード（preupgrade）およびポストアップグレード（postupgrade）のシステムメソッド

変数を `stable` なものとして宣言するには、その型もステーブル型である必要があります。 すべての型がステーブルであるわけではないので、いくつかの変数は `stable` と宣言することができません。

簡単な例として、[直交永続性](motoko.md#orthogonal_persistence) の議論にある `Registry` Actor を考えてみましょう。

```motoko file=./examples/Registry.mo

```

この Actor は、`map` オブジェクトのサイズを使用して次の ID を決定することで、`Text` 値に連続した ID を割り当てます。 他の Actor と同様に、呼び出しの間にハッシュマップのステートを維持するために _直交永続性_ を頼っています。

ここで、私たちはアップグレードによって既存の記録を失なうことなく `Register` をアップグレード可能にしたいとします。

残念なことに、ステートである `map` はメンバ関数（例えば `map.get`）を含むオブジェクト型を持っているので、`map` 変数自身を `stable` と宣言することはできません。

このようなステーブル変数だけでは解決できないシナリオのために、Motoko はユーザー定義のアップグレードフック（upgrade hook）をサポートしており、使用するとアップグレードの前後にすぐさま実行されます。 これらのアップグレードフックによって、制限のないフレキシブル変数と、より制限のあるステーブル変数との間でステートを移行させることができます。 これらのフックは `system` 関数として宣言され、特別な名前（`preugrade` と `postupgrade`）がついています。どちらの関数も型は `: () → ()` である必要があります。

`preupgrade` メソッドを使用すると、ランタイムがステーブルメモリに値をコミットしてアップグレードを行う前に、ステーブル変数に最終的な更新を行うことができます。 `postupgrade` メソッドは、アップグレードがステーブル変数を含む新たな Actor を初期化した後、その Actor で shared 関数の呼び出し（メッセージ）を行う前に実行されます。

ここでは、新しいステーブル変数 `entries` を導入し、stable でないハッシュテーブルのエントリを保存・復元します。

```motoko file=./examples/StableRegistry.mo

```

`entries` の型は、単に `Text` と `Nat` のペアの配列であり、実際にステーブル型であることに注目してください。

この例では、 `preupgrade` システムメソッドは、 `entries` をステーブルメモリに保存する前に、現在の `map` エントリを `entries` に単に書き込んでいます。 `postupgrade` システムメソッドは、`entries` から `map` の空き領域に値を埋めた後、 `entries` を空の配列にリセットしています。

## ステーブル型のシグネチャ

Actor 内のステーブル変数宣言のコレクションは、_ステーブルシグネチャ（stable signature）_ にまとめることができます。

Actor のステーブルシグネチャのテキスト表現は Motoko Actor 型の内部構造と似ています。

```motoko no-repl
actor {
  stable x : Nat;
  stable var y : Int;
  stable z : [var Nat];
};
```

これは Actor のステーブルフィールドの名前・型・ミュータブルかどうかを指定しています。 場合によっては関連する Motoko の型宣言を前に行うこともあります。

:::tip

`moc` コンパイラのオプションである `--stable-types` を使うと、メインの Actor や Actor クラスのステーブルシグネチャを `.most` ファイルに出力することができます。 そのため、自分で `.most` ファイルを作成する必要はありません。

:::

ステーブルシグネチャ `<stab-sig1>` は、以下の場合に限り、シグネチャ `<stab-sig2>` と _ステーブル互換（stable-compatible）_ となります。

- `<stab-sig1>` のすべてのイミュータブルフィールド `stable <id> : T` は、 `<stab-sig2>` のフィールド `stable <id> : U` と一致し、`T <: U` である（訳注：`<:` はサブタイプ記号であり、`A <: B` なら A は B のサブタイプ）。

- `<stab-sig1>` の全てのミュータブルフィールド `stable var <id> : T` は `<stab-sig2>` のフィールド `stable var <id> : U` とマッチし、`T <: U` である。

`<stab-sig2>` には追加のフィールドが含まれている可能性があることに注意してください。 通常 `<stab-sig1>` は古いバージョンのシグネチャで、`<stab-sig2>` は新しいバージョンのシグネチャです。

ステーブルフィールドのサブタイピング条件は、あるフィールドの最終的な値が、アップグレード後のコードでそのフィールドの初期値として使われることを保証します。

:::tip

`moc` コンパイラのオプションである `--stable-compatible cur.most nxt.most` を使用すると、（ステーブルシグネチャを含む）2 つの `.most` ファイル（`cur.most` と `nxt.most`）のステーブル互換性（stable-compatiblity）を確認することができます。

:::

:::note

_ステーブル互換_ の関係は、かなり保守的なものです。 将来的には、フィールドのミュータビリティの変更や `<stab-sig1>` からのフィールドの放棄（ただし警告を伴う）に対応するために緩和されるかもしれません。

:::

## アップグレードの安全性

デプロイされた Canister をアップグレードする前に、アップグレードが安全で、以下のようなことがないことを確認する必要があります。

- （Candid インターフェース変更によって）既存のクライアントが壊れる。

- （ステーブル宣言の互換性のない変更によって）Motoko のステーブルステートを破棄する。

Motoko Canister のアップグレードは、以下の条件を満たせば安全です。

- Canister の Candid インターフェースが Candid におけるサブタイプになっている。

- Canister の Motoko ステーブルシグネチャが、_ステーブル互換_ なものになっている。

アップグレードの安全性は、アップグレード処理が成功することを保証するものではありません（リソースの制約により失敗する可能性はあります）。 しかし、少なくともアップグレードが成功すれば、既存のクライアントとの Candid 型の互換性が失われたり、`stable` とマークされていたデータが予期せず失われたりしないことを保証するはずです。

:::tip

`didc` ツールに `check nxt.did cur.did` という引数を与えることで、（Candid 型を含む) `cur.did` と `nxt.did` という `.did` ファイルに記述された 2 つの Service 間における有効な Candid のサブタイプのチェックを行うことができます。 `didc` ツールは <https://github.com/dfinity/candid> で入手可能です。

:::

## メタデータセクション

Motoko のコンパイラは、Canister の Candid インターフェースとステーブルシグネチャを、Canister のメタデータとして埋め込み、コンパイル済みバイナリの Wasm カスタムセクションに記録します。

このメタデータは IC によって選択的に公開され、`dfx` のようなツールによってアップグレードの互換性を検証するために使用されます。

## すでにデプロイされた Actor または Canister スマートコントラクトのアップグレード

適切な `stable` 変数、または `preupgrade` と `postupgrade` システムメソッドを用いて Motoko Actor をデプロイした後、`dfx canister install` コマンドに `--mode=upgrade` オプションを指定すると、既にデプロイしたバージョンをアップグレードすることが可能です。 デプロイされた Canister のアップグレードに関する情報は [Canister スマートコントラクトのアップグレード](../../project-setup/manage-canisters.md#upgrade-a-canister) を参照してください。

今後の `dfx` のバージョンでは、デプロイされたバイナリとアップグレードバイナリに埋め込まれた Candid と (Motoko で書かれた Canister のみ) ステーブルシグネチャを比較してアップグレードの安全性を確認し、安全ではない場合はアップグレード要求を中止するようになります。

<!--
# Stable variables and upgrade methods

One key feature of the Internet Computer is its ability to persist canister smart contract state using WebAssembly memory and globals rather than a traditional database. This means that that the entire state of a canister is magically restored before, and saved after, each message, without explicit user instruction. This automatic and user-transparent preservation of state is called *orthogonal persistence*.

Though convenient, orthogonal persistence poses a challenge when it comes to upgrading the code of a canister. Without an explicit representation of the canister’s state, how does one tranfer any application data from the retired canister to its replacement?

Accommodating upgrades without data loss requires some new facility to *migrate* a canister’s crucial data to the upgraded canister. For example, if you want to deploy a new version of a user-registration canister to fix an issue or add functionality, you need to ensure that existing registrations survive the upgrade process.

The Internet Computer’s persistence model allows a canister to save and restore such data to dedicated *stable memory* that, unlike ordinary canister memory, is retained across an upgrade, allowing a canister to transfer data in bulk to its replacement canister.

For applications written in Motoko, the language provides high-level support for preserving state that leverages Internet Computer stable memory. This higher-level feature, called *stable storage*, is designed to accommodate changes to both the application data and to the Motoko compiler used to produce the application code.

Utilizing stable storage depends on you — as the application programmer — anticipating and indicating the data you want to retain after an upgrade. Depending on the application, the data you decide to persist might be some, all, or none of a given actor’s state.

-->
<!--
To enable Motoko to migrate the current state of variables when a canister is upgraded, you must identify those variables as containing data that must be preserved.
-->
<!--

## Declaring stable variables

In an actor, you can nominate a variable for stable storage (in Internet Computer stable memory) by using the `stable` keyword as a modifier in the variable’s declaration.

More precisely, every `let` and `var` variable declaration in an actor can specify whether the variable is `stable` or `flexible`. If you don’t provide a modifier, the variable is declared as `flexible` by default.

-->
<!--
Concretely, you use the following syntax to declare stable or flexible variables in an actor:

....
<dec-field> ::=
  (public|private)? (stable|flexible)? dec
....
-->
<!--

The following is a simple example of how to declare a stable counter that can be upgraded while preserving the counter’s value:

``` motoko file=./examples/StableCounter.mo
```

:::note

You can only use the `stable` or `flexible` modifier on `let` and `var` declarations that are **actor fields**. You cannot use these modifiers anywhere else in your program.

:::

## Typing

Because the compiler must ensure that stable variables are both compatible with and meaningful in the replacement program after an upgrade, the following type restrictions apply to stable state:

-   every `stable` variable must have a *stable* type

where a type is *stable* if the type obtained by ignoring any `var` modifiers within it is *shared*.

Thus the only difference between stable types and shared types is the former’s support for mutation. Like shared types, stable types are restricted to first-order data, excluding local functions and structures built from local functions (such as objects). This exclusion of functions is required because the meaning of a function value — consisting of both data and code — cannot easily be preserved across an upgrade, while the meaning of plain data — mutable or not — can be.

:::note

In general, object types are not stable because they can contain local functions. However, a plain record of stable data is a special case of object types that is stable. Moreover, references to actors and shared functions are also stable, allowing you to preserve their values across upgrades. For example, you can preserve state recording a set of actors or shared function callbacks subscribing to a service.

:::

## How stable variables are upgraded

When you first compile and deploy a canister, all flexible and stable variables in the actor are initialized in sequence. When you deploy a canister using the `upgrade` mode, all stable variables that existed in the previous version of the actor are pre-initialized with their old values. After the stable variables are initialized with their previous values, the remaining flexible and newly-added stable variables are initialized in sequence.

## Preupgrade and postupgrade system methods

Declaring a variable to be `stable` requires its type to be stable too. Since not all types are stable, some variables cannot be declared `stable`.

As a simple example, consider the `Registry` actor from the discussion of [orthogonal persistence](motoko.md#orthogonal-persistence).

``` motoko file=./examples/Registry.mo
```

This actor assigns sequential identifiers to `Text` values, using the size of the underlying `map` object to determine the next identifier. Like other actors, it relies on *orthogonal persistence* to maintain the state of the hashmap between calls.

We’d like to make the `Register` upgradable, without the upgrade losing any existing registrations.

Unfortunately, its state, `map`, has a proper object type that contains member functions (for example, `map.get`), so the `map` variable cannot, itself, be declared `stable`.

For scenarios like this that can’t be solved using stable variables alone, Motoko supports user-defined upgrade hooks that, when provided, run immediately before and after upgrade. These upgrade hooks allow you to migrate state between unrestricted flexible variables to more restricted stable variables. These hooks are declared as `system` functions with special names, `preugrade` and `postupgrade`. Both functions must have type `: () → ()`.

The `preupgrade` method lets you make a final update to stable variables, before the runtime commits their values to Internet Computer stable memory, and performs an upgrade. The `postupgrade` method is run after an upgrade has initialized the replacement actor, including its stable variables, but before executing any shared function call (or message) on that actor.

Here, we introduce a new stable variable, `entries`, to save and restore the entries of the unstable hash table.

``` motoko file=./examples/StableRegistry.mo
```

Note that the type of `entries`, being just an array of `Text` and `Nat` pairs, is indeed a stable type.

In this example, the `preupgrade` system method simply writes the current `map` entries to `entries` before `entries` is saved to stable memory. The `postupgrade` system method resets `entries` to the empty array after `map` has been populated from `entries` to free space.

## Stable type signatures

The collection of stable variable declarations in an actor can be summarized in a *stable signature*.

The textual representation of an actor’s stable signature resembles the internals of a Motoko actor type:

``` motoko no-repl
actor {
  stable x : Nat;
  stable var y : Int;
  stable z : [var Nat];
};
```

It specifies the names, types and mutability of the actor’s stable fields, possibly preceded by relevant Motoko type declarations.

:::tip

You can emit the stable signature of the main actor or actor class to a `.most` file using `moc` compiler option `--stable-types`. You should never need to author your own `.most` file.

:::

A stable signature `<stab-sig1>` is *stable-compatible* with signature `<stab-sig2>`, if, and only,

-   every immutable field `stable <id> : T` in `<stab-sig1>` has a matching field `stable <id> : U` in `<stab-sig2>` with `T <: U`.

-   every mutable field `stable var <id> : T` in `<stab-sig1>` has a matching field `stable var <id> : U` in `<stab-sig2>` with `T <: U`.

Note that `<stab-sig2>` may contain additional fields. Typically, `<stab-sig1>` is the signature of an older version while `<stab-sig2>` is the signature of a newer version.

The subtyping condition on stable fields ensures that the final value of some field can be consumed as the initial value of that field in the upgraded code.

:::tip

You can check the stable-compatiblity of two `.most` files, `cur.most` and `nxt.most` (containing stable signatures), using `moc` compiler option `--stable-compatible cur.most nxt.most`.

:::

:::note

The *stable-compatible* relation is quite conservative. In the future, it may be relaxed to accommodate a change in field mutability and/or abandoning fields from `<stab-sig1>` (but with a warning).

:::

## Upgrade safety

Before upgrading a deployed canister, you should ensure that the upgrade is safe and will not

-   break existing clients (due to a Candid interface change); or

-   discard Motoko stable state (due to an incompatible change in stable declarations).

A Motoko canister upgrade is safe provided:

-   the canister’s Candid interface evolves to a Candid subtype; and

-   the canister’s Motoko stable signature evolves to a *stable-compatible* one.

Upgrade safety does not guarantee that the upgrade process will succeed (it can still fail due to resource constraints). However, it should at least ensure that a successful upgrade will not break Candid type compatibility with existing clients or unexpectedly lose data that was marked `stable`.

:::tip

You can check valid Candid subtyping between two services described in `.did` files, `cur.did` and `nxt.did` (containing Candid types), using the `didc` tool with argument `check nxt.did cur.did`. The `didc` tool is available at <https://github.com/dfinity/candid>.

:::

## Metadata sections

The Motoko compiler embeds the Candid interface and stable signature of a canister as canister metadata, recorded in additional Wasm custom sections of a compiled binary.

This metadata can be selectively exposed by the IC and used by tools such as `dfx` to verify upgrade compatibility.

## Upgrading a deployed actor or canister smart contract

After you have deployed a Motoko actor with the appropriate `stable` variables or `preupgrade` and `postupgrade` system methods, you can use the `dfx canister install` command with the `--mode=upgrade` option to upgrade an already deployed version. For information about upgrading a deployed canister, see [Upgrade a canister smart contract](../../project-setup/manage-canisters.md#upgrade-a-canister).

An upcoming version of `dfx` will, if appropriate, check the safety of an upgrade by comparing the Candid and (for Motoko canisters only) the stable signatures embedded in the deployed binary and upgrade binary, and abort the upgrade request when unsafe.

-->
