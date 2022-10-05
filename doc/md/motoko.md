# Motoko Programming Language# Motoko プログラミング言語

:::tip

Motoko プログラミング言語は、 DFINITY Canister SDK のリリースや、 Motoko コンパイラのアップデートを経て進化を続けています。 新しい機能を試したり、何が変わったのかを知るために、定期的に戻って確認しに来ましょう。

:::

Motoko プログラミング言語は、Internet Computer ブロックチェーンネットワーク上で動く次世代の Dapps をビルドしたい開発者のための、新しく現代的で型安全な言語です。 Motoko は、Internet Computer のユニークな機能をサポートし、親しみやすいけど頑丈なプログラミング環境を提供するよう、特別に設計されています。 新しい言語として Motoko は、新たな機能や改善のサポートを経て進化し続けています。

Motoko コンパイラ、ドキュメント、また他のツールは、 [オープンソース](https://github.com/dfinity/motoko) であり、Apache 2.0 ライセンスのもとでリリースされています。コントリビュートは歓迎です。

## ネイティブ Canister スマートコントラクトサポート

Motoko は、Internet Computer Canister スマートコントラクトをネイテイブサポートしています。

Canister スマートコントラクト (または略して Canister) は、 Motoko Actor として表されます。 Actor とは、そのステートを完全にカプセル化して、非同期メッセージでのみ別の Actor との通信を行う自律的なオブジェクトです。

```motoko name=counter file=./examples/Counter.mo

```

## ダイレクトスタイルでシーケンシャルにコードを書く

Internet Computer 上では、Canisters は他の Canisters と非同期のメッセージを送ることでコミュニケーションができます。

非同期のプログラミングは難しいので、Motoko はより単純なシーケンシャルスタイルでコードを書くことを可能にしています。非同期のメッセージは _future_ を返す関数呼び出しであり、`await` コンストラクトは future が完了するまで処理を延期することを許可します。この単純な機能は、他の言語でも不適切である非同期プログラミングでの"コールバック地獄"を回避します。

```motoko include=counter file=./examples/factorial.mo#L9-L21

```

## 現代的な型システム

Motoko は、JavaScript や他の有名言語と直感的に馴染みやすくなるよう設計されていますが、構造的型、ジェネリクス、バリアント型、または静的なパターンマッチングのような現代的な機能も提供します。

```motoko file=./examples/tree.mo

```

## 自動生成の IDL ファイル

Motoko Actor は、引数と返り値の型を示す関数として、常に型付けされたインターフェースをクライアントに、提供しています。

Motoko コンパイラー（かつ SDK ）は、Candid と呼ばれる言語に依存しないフォーマットでこのインターフェースを出力するので、Candid をサポートしている別の Canisters やブラウザ上のコードやスマートフォンアプリは、Actor のサービスを利用することができます。Motoko コンパイラは、Candid ファイルを使用したり生成したりすることができ、Motoko にシームレスに（ Candid をサポートしている）他の言語で実装された Canister と接続することを可能にします。

例えば、上で示した Motoko の `Counter` Actor は、次に続く Candid インターフェースを持っています。

```candid
service Counter : {
  inc : () -> (nat);
}
```

## 直交永続性

Internet Computer は、作動している Canister のメモリと他のステートも保持しています。それゆえ、Motoko Actor のステートは、そのインメモリデータ構造も含め永久に残り続けます。Actor のステートは、それぞれのメッセージと共に復元することや外部ストレージに保存することを明確に必要としていません。

例えば、シーケンシャルな ID をテキストの名前に割り当てる次の `Registry` Actor (Canister) では、Actor のステートがたくさんの Internet Computer ノードマシーンで複製されたもので、一般的にメモリ内にはいないれども、ハッシュテーブルのステートはコールを介して保存されています。

```motoko file=./examples/Registry.mo

```

## アップグレード

Motoko は、Canister のコードをアップグレードするとき Canister のデータを保持できることを許可する言語機能を含めた、直交永続性を活用するのを助ける数多くの機能を提供しています。

例えば、Motoko は、ある変数を `stable` として宣言することができます。 `stable` 変数の値は、 Canister アップグレードでも自動的に保持されます。

stable カウンターを考えてみましょう。

```motoko file=./examples/StableCounter.mo

```

インストール後に _n_ 回インクリメントされ、その後中断することなく、より多機能な実装へとアップグレードすることができます。

```motoko file=./examples/StableCounterUpgrade.mo

```

`value` は `stable` として宣言されていたので、現在のステートやサービスの n はアップグレードの後でも保持されています。カウンティングは、0 から再度始まるのではなく、n 回目から始まります。

その新しいインターフェースは過去のものと互換性がありますので、既に存在している Canister に関するクライアントは動作を続けていきますが、新しいクライアントは、アップグレードした機能を最大限利用することもできます。（追加の `reset` 機能）

stable な変数の使用のみでは解決できないシナリオのために、Motoko は、アップグレードの前後で即座に動作するかつ任意のステートを静的な変数にすることを許可する、ユーザーが定義できるアップグレードフックを提供しています。

## さらなる機能

Motoko は、サブタイピング、任意精度演算、またはガベージコレクションを含めた、多くの開発者の生産性を上げる機能を提供しています。

Motoko は、スマートコントラクト Canister を導入するためだけの言語ではなく、またそうであることを意図していません。もしあなたのニーズを満たさない時のために、Rust プログラミング言語の CDK があります。 私達の目標は、言語に左右されない Candid インターフェースを通し、他国の Canister スマートコントラクトと一緒に Internet Computer 上で動作する Canister スマートコントラクトを、いかなる言語でも作成できるようにすることです。

そのオーダーメイド設計は、少なくともしばらくの間 Motoko が Internet Computer 上でのコーディングにおいて最も簡単かつ安全な言語であろうことを意味しています。

<!--

:::tip

The Motoko programming language continues to evolve with each release of the DFINITY Canister SDK and with ongoing updates to the Motoko compiler. Check back regularly to try new features and see what’s changed.

:::

The Motoko programming language is a new, modern and type safe language for developers who want to build the next generation of distributed applications to run on the Internet Computer blockchain network. Motoko is specifically designed to support the unique features of the Internet Computer and to provide a familiar yet robust programming environment. As a new language, Motoko is constantly evolving with support for new features and other improvements.

The Motoko compiler, documentation and other tooling is [open source](https://github.com/dfinity/motoko) and released under the Apache 2.0 license. Contributions are welcome.

## Native canister smart contract support

Motoko has native support for Internet Computer canister smart contracts.

A canister smart contract (or canister for short) is expressed as a Motoko actor. An actor is an autonomous object that fully encapsulates its state and communicates with other actors only through asynchronous messages.

For example, this code defines a stateful `Counter` actor.

``` motoko name=counter file=./examples/Counter.mo
```

Its single public function, `inc()`, can be invoked by this and other actors, to both update and read the current state of its private field `value`.

## Code sequentially in direct style

On the Internet Computer, canisters can communicate with other canisters by sending asynchronous messages.

Asynchronous programming is hard, so Motoko enables you to author asynchronous code in much simpler, sequential style. Asynchronous messages are function calls that return a *future*, and the `await` construct allows you to suspend execution until a future has completed. This simple feature avoids the "callback hell" of explicit asynchronous programming in other languages.

``` motoko include=counter file=./examples/factorial.mo#L9-L21
```

## Modern type system

Motoko has been designed to be intuitive to those familiar with JavaScript and other popular languages, but offers modern features such as sound structural types, generics, variant types, and statically checked pattern matching.

``` motoko file=./examples/tree.mo
```

## Autogenerated IDL files

A Motoko actor always presents a typed interface to its clients as a suite of named functions with argument and (future) result types.

The Motoko compiler (and SDK) can emit this interface in a language neutral format called Candid, so other canisters, browser resident code and smart phone apps that support Candid can use the actor’s services. The Motoko compiler can consume and produce Candid files, allowing Motoko to seamlessly interact with canisters implemented in other programming languages (provided they support Candid).

For example, the previous Motoko `Counter` actor has the following Candid interface:

``` candid
service Counter : {
  inc : () -> (nat);
}
```

## Orthogonal persistence

The Internet Computer persists the memory and other state of your canister as it executes. Thus the state of a Motoko actor, including its in-memory data structures, survive indefinitely. Actor state does not need to be explicitly "restored" and "saved" to external storage, with every message.

For example, in the following `Registry` actor (canister), that assigns sequential IDs to textual names, the state of the hash table is preserved across calls, even though the state of the actor is replicated across many Internet Computer node machines, and typically not resident in memory.

``` motoko file=./examples/Registry.mo
```

## Upgrades

Motoko provides numerous features to help you leverage orthogonal persistence, including language features that allow you to retain a canister’s data as you upgrade the code of the canister.

For example, Motoko lets you declare certain variables as `stable`. The values of `stable` variables are automatically preserved across canister upgrades.

Consider a stable counter:

``` motoko file=./examples/StableCounter.mo
```

It can be installed, incremented *n* times, and then upgraded, without interruption, to, for example, the richer implementation:

``` motoko file=./examples/StableCounterUpgrade.mo
```

Because `value` was declared `stable`, the current state, *n*, of the service is retained after the upgrade. Counting will continue from *n*, not restart from `0`.

Because the new interface is compatible with the previous one, existing clients referencing the canister will continue to work, but new clients will be able to exploit its upgraded functionality (the additional `reset` function).

For scenarios that can’t be solved using stable variables alone, Motoko provides user-definable upgrade hooks that run immediately before and after upgrade, and allow you to migrate arbitrary state to stable variables.

## And more …​

Motoko provides many other developer productivity features, including subtyping, arbitrary precision arithmetic and garbage collection.

Motoko is not, and is not intended to be, the only language for implementing canister smart contracts. If it doesn’t suit your needs, there is a canister development kit (CDK) for the Rust programming language. Our goal is to enable any language (with a compiler that targets WebAssembly) to be able to produce canister smart contracts that run on the Internet Computer and interoperate with other, perhaps foreign, canister smart contracts through language neutral Candid interfaces.

Its tailored design means Motoko should be the easiest and safest language for coding on the Internet Computer, at least for the forseeable future.

-->
