# イントロダクション

Motoko は、[Internet Computer](../../../../concepts/what-is-IC.md) 上で動作するスマートコントラクトの Canister の開発に特化した、最新の汎用プログラミング言語です。 この言語は Internet Computer を直接のターゲットにしていますが、将来的に他のターゲットへのコンパイルをサポートするのに十分な程度には一般的な設計になっています。

## アプローチ性（言語の親しみやすさ）

Motoko は、JavaScript、Rust、Swift、TypeScript、C#、Java などのモダンプログラミング言語を通してオブジェクト指向や関数型プログラミングのイディオムに基本的な知識を持っているプログラマーが親しみやすいように設計されたモダン言語です。

## 非同期メッセージングと型安全な実行

Motoko は、分散型アプリケーション（Dapps）のための特別なプログラミング抽象化を含む、モダンプログラミングのイディオムを使用可能にしています。 それぞれの Dapps は、_非同期のメッセージパッシング_ のみで通信する、1 つまたは複数の _Actor_ で構成されます。Actor のステートは、他のすべての Actor から分離されており、分散性をサポートしています。複数の Actor 間でステートを共有する方法はありません。 Motoko の Actor ベースのプログラミングの抽象化は、人間が読めるメッセージパッシングのパターンによってプログラミングすることを可能にし、各ネットワークの相互作用が特定のルールに従うことや、よくある間違いを避けることを強制します。

具体的には、Motoko プログラムは実行前に各プログラムをチェックする実用的でモダンな型システムが含まれているため、_型健全_ です。 Motoko の型システムは、Motoko のプログラムが、可能なすべての入力に対して動的な型エラーを起こさずに安全に実行されるかどうかを静的にチェックします。 その結果、他の言語、特に Web プログラミング言語でよく見られるプログラミング上の落とし穴の類の全てが除外されます。これには、NULL 参照エラー、引数や返り値の型のミスマッチ、フィールドの欠落エラーなどが含まれます。

実行時には、Motoko は、[WebAssembly](about-this-guide.md#webassembly) という、モダンコンピュータハードウェアをきれいに抽象化したポータブルなバイナリフォーマットに静的にコンパイルし、インターネット上で広く実行したり、[Internet Computer](../../../../concepts/what-is-IC.md) 上で実行したりすることを可能にしています。

## _Actor_ としての各 Canister スマートコントラクト

Motoko は、[Internet Computer](../../../../concepts/what-is-IC.md) 上の Canister スマートコントラクトのものを含む Service を表現するための **Actor ベース** のプログラミングモデルを開発者に提供しています。

Actor はオブジェクトに似ていますが、そのステートが完全に分離されており、世界中とのやりとりがすべて _非同期_ メッセージングで行われる点が特別です。

Actor との間のすべてのコミュニケーションは、Internet Computer のメッセージングプロトコルを使い、ネットワーク上で非同期にメッセージを渡しています。 Actor のメッセージは順番に処理されるので、ステートの変更が競合状態を認めることはありません（`await` 式の区切りによって明示的に許可されている場合を除く）。

Internet Computer は、送信された各メッセージが確実に応答を受け取ることを保証します。レスポンスは、ある値を持つ成功ステータスか、エラーのいずれかです。エラーには、受信側の Canister による明示的なメッセージの拒否、ゼロ除算などの不正な命令によるトラップ、配布やリソースの制約によるシステムエラーなどがあります。例えば、システムエラーとは、受信者が一時的または恒久的に利用できないことです（受信 Actor にアクセス集中しているか、削除されているかのいずれか）。

### 非同期 Actor

他の _モダン_ プログラミング言語と同様に、Motoko はコンポーネント間の _非同期_ コミュニケーションのための人間工学的なシンタックスを認めています。

Motoko の場合、通信している各コンポーネントが Actor です。

Actor を _使う_ 例として（おそらく自分自身も _Actor_ だと考えるのがよいでしょう）、この 3 行のプログラムを考えてみましょう。

```motoko no-repl
let result1 = service1.computeAnswer(params);
let result2 = service2.computeAnswer(params);
finalStep(await result1, await result2)
```

このプログラムの動作は、3 つのステップでまとめることができます：

1.  プログラムは、Motoko Actor または他の言語で実装された Canister スマートコントラクトとして実装された 2 つの異なる Service に対して、2 つのリクエスト（1 行目と 2 行目）を行います。

2.  プログラムは、各返り値に対してキーワード `await` を用いて、各返り値の準備ができるのを待ちます（3 行目）。

3.  プログラムは、最終ステップ（3 行目）で `finalStep` 関数を呼び出して、両方の結果を使用します。

一般的に言えば、Service は互いに待つのではなく、実行を _インターリーブ_ することで全体の待ち時間を短縮することができます。 しかし、特別な言語サポート _なし_ にこの方法で待ち時間を短縮しようとすると、そのようなインターリーブにはすぐに明快さや単純さが犠牲となります。

インターリーブ実行が _ない_ 場合（例えば、上記の呼び出しが 2 つではなく 1 つだけの場合）でも、同じ理由で、プログラミングの抽象化によって明確さと単純さを実現しています。 つまり、プログラムを変換する場所をコンパイラに知らせることで、背後にあるシステムのメッセージパッシングループによる実行をインターリーブするために、プログラマがプログラムロジックを歪めることをせずにすみます。

このプログラムでは、3 行目で `await` を使用することで、そのインターリーブ動作を　 Motoko が提供する人間が読めるシンタックスでシンプルに表現しています。

このような抽象化がなされていない言語環境では、開発者は単にこれらの 2 つの関数を直接呼び出すのではなく、非常に高度なプログラミングパターンを採用することになります。おそらくシステムが提供する `イベントハンドラ` の中に開発者が提供する `コールバック関数` を登録することになるでしょう。

各コールバックは、呼び出した関数の返り値の準備ができたときに発生する非同期イベントを処理することになります。このようなシステムレベルのプログラミングは強力ですが、高レベルのデータフローを、共有されているステートを通じて通信する低レベルのシステムイベントに分解することになるため、非常にエラーが発生しやすいです。 このようなプログラミングスタイルが必要な場合もありますが、ここではそうではありません。

私たちのプログラムは、このような煩雑なプログラミングスタイルを避け、代わりにより自然な _ダイレクト_ スタイルを採用しており、各リクエストは通常の関数呼び出しに近い形となっています。 この、よりシンプルで様式化されたプログラミング形式は、今日のほとんどのモダンソフトウェアがそうであるように、_外部環境_ と相互作用する実用的なシステムの表現としてますます人気が高まっています。

しかし、これには特別なコンパイラと型システムのサポートが必要で、その詳細については後述します。

### _非同期_ 動作のサポート

_非同期_ コンピューティングでは、プログラムとその実行環境は、互いに _並行_ して実行される _内部計算_ を行うことができます。

具体的には、非同期プログラムとは、プログラムの実行を計算環境に要求した場合に、その完了を待つ必要が（必ずしも）ないものです。 同時に、計算環境が要求された計算を完了するまでの間、プログラムはその環境の中で内部計算を行うことが許されます。上の例では、プログラムは最初の要求が完了するのを待つ前に 2 番目の要求を発行します。

対称的に、環境側がプログラムに要求することは、プログラムの回答を待つことを（必ずしも）必要としません。 環境側は、プログラム側で答えが生成される間に外部で計算を進行することができます。

上では、この “通知” パターンの例を示していませんが、これはコールバック（および _高次_ 関数と制御フロー）を使用するため、より複雑になるからです。

### `async` / `await` 構文

わかりやすさとシンプルさへのニーズに対応するために、Motoko では急速に普及している `async` と `await` というプログラム構成を採用しています。これは、複雑になりがちな非同期の依存関係グラフを記述するための _構造化された_ 言語をプログラマにもたらします。

[async](language-manual.md#async) の構文によって、Future が導入されます。 Future の値は _将来的に非同期に配信される_ 結果の _promise_ を表します（上の最初の例では示されていません）。 Future については、[Actor と async データ](actors-async.md)で Actor を導入した際により詳しく学びます。

ここでは単純に、`service1.computeAnswer(params)` と `service2.computeAnswer(params)` を呼び出した際に返ってくる値を使用します。

`await` 構文を用いると Future に同期し、その生成元によって Future が完了するまで計算を中断します。 上の例では、2 つの Service の呼び出しから結果を得るために、`await` が 2 つ使われています。

開発者がこれらのキーワードを使用すると、コンパイラは必要に応じてプログラムを変換します。多くの場合、純粋に同期的な言語では手作業で実行するのが面倒な、プログラムの制御フローやデータフローの複雑な変換を行います。 一方、Motoko の型システムでは、型の生成側と使用側を流れる型は常に一致しており、Sercive 間で送信されるデータ型は行き来することが許可されていること、そして（例えば）[プライベートな可変型ステート](mutable-state.md) を含まないことなど、これらの構成要素の一定の正しい使用パターンが強制されます。

### 型と Static

他のモダンプログラミング言語と同様、Motoko では、各変数に関数やオブジェクト、プリミティブなデータ（文字列、単語、整数など）の値を入れることができます。レコード、タプル、_バリアント_ と呼ばれる “タグ付けされたデータ” など、他の [値の型](basic-concepts.md#intro-values) も使用可能です。

Motoko は、_型の健全性_ としても知られる型安全性の形式的な特性を享受しています。 この考え方は、[正しく型付けされた Motoko プログラムは間違いを起こさない](basic-concepts.md#type-soundness) というフレーズでしばしばまとめられます。これは、データに対して実行される操作は、その静的な型によって許可されるものだけであるという意味です。

例えば、Motoko プログラムの各変数には関連する _型_ があり、この型はプログラムが実行される前に _静的に_ 知られています。 各変数の使用はコンパイラによってチェックされ、NULL 参照エラー、無効なフィールドアクセスなどの実行時の型エラーを防ぎます。

この意味で、Motoko の型は、プログラムのソースコードの中で、_信頼できる、**コンパイラが検証した** ドキュメント_ を提供します。

通常通り、動的テストでは Motoko の型システムの手の届かないところにあるプロパティをチェックすることができます。 Motoko の型システムはモダンではありますが、意図的に `先進的` ではなく、特に風変わりなものでもありません。 むしろ、Motoko の型システムは、モダンでありながら非常に理解しやすい、[実用的な型システム](about-this-guide.md#modern-type-systems)の標準的な概念を統合し、汎用の分散アプリケーションをプログラミングするための、親しみやすく表現力豊かでありながらも安全な言語を提供しています。

<!--

# Introduction

Motoko is a modern, general-purpose programming language you can use specifically to author [Internet Computer](../../../../concepts/what-is-IC.md) canister smart contracts. Although aimed squarely at the Internet Computer, its design is general enough to support future compilation to other targets.

## Approachability

Motoko is a modern language designed to be approachable for programmers who have some basic familiarity with modern object-oriented and/or functional programming idioms in either JavaScript, or another modern programming language, such as Rust, Swift, TypeScript, C#, or Java.

## Asynchronous messaging and type sound execution

Motoko permits modern programming idioms, including special programming abstractions for distributed applications (dapps). Each dapp consists of one or more *actors* that communicate solely by *asynchronous message passing*. The state of an actor is isolated from all other actors, supporting distribution. There is no way to share state between several actors. The actor-based programming abstractions of Motoko permit human-readable message-passing patterns, and they enforce that each network interaction obeys certain rules and avoids certain common mistakes.

Specifically, Motoko programs are *type sound* since Motoko includes a practical, modern type system that checks each one before it executes. The Motoko type system statically checks that each Motoko program will execute safely, without dynamic type errors, on all possible inputs. Consequently, entire classes of common programming pitfalls that are common in other languages, and web programming languages in particular, are ruled out. This includes null reference errors, mis-matched argument or result types, missing field errors and many others.

To execute, Motoko statically compiles to [WebAssembly](about-this-guide.md#webassembly), a portable binary format that abstracts cleanly over modern computer hardware, and thus permits its execution broadly on the Internet, and the [Internet Computer](../../../../concepts/what-is-IC.md).

## Each canister smart contract as an *actor*

Motoko provides an **actor-based** programming model to developers to express *services*, including those of canister smart contracts on the [Internet Computer](../../../../concepts/what-is-IC.md).

An actor is similar to an object, but is special in that its state is completely isolated, and all its interactions with the world are by *asynchronous* messaging.

All communication with and between actors involves passing messages asynchronously over the network using the Internet Computer’s messaging protocol. An actor’s messages are processed in sequence, so state modifications never admit race conditions (unless explicitly allowed by punctuating `await` expressions).

The Internet Computer ensures that each message that is sent receives a response. The response is either success with some value, or an error. An error can be the explicit rejection of the message by the receiving canister, a trap due to an illegal instruction such as division by zero, or a system error due to distribution or resource constraints. For example, a system error might be the transient or permanent unavailability of the receiver (either because the receiving actor is oversubscribed or has been deleted).

### Asynchronous actors

Like other *modern* programming languages, Motoko permits an ergonomic syntax for *asynchronous* communication among components.

In the case of Motoko, each communicating component is an actor.

As an example of *using* actors, perhaps as an actor ourselves, consider this three-line program:

``` motoko no-repl
let result1 = service1.computeAnswer(params);
let result2 = service2.computeAnswer(params);
finalStep(await result1, await result2)
```

We can summarize the program’s behavior with three steps:

1.  The program makes two requests (lines 1 and 2) to two distinct services, each implemented as a Motoko actor or canister smart contract implemented in some other language.

2.  The program waits for each result to be ready (line 3) using the keyword `await` on each result value.

3.  The program uses both results in the final step (line 3) by calling the `finalStep` function.

Generally-speaking, the services *interleave* their executions rather than wait for one another, since doing so reduces overall latency. However, if we try to reduce latency this way *without* special language support, such interleaving will quickly sacrifice clarity and simplicity.

Even in cases where there are *no* interleaving executions (for example, if there were only one call above, not two), the programming abstractions still permit clarity and simplicity, for the same reason. Namely, they signal to the compiler where to transform the program, freeing the programmer from contorting the program’s logic in order to interleave its execution with the underlying system’s message-passing loop.

Here, the program uses `await` in line 3 to express that interleaving behavior in a simple fashion, with human-readable syntax that is provided by Motoko.

In language settings that lack these abstractions, developers would not merely call these two functions directly, but would instead employ very advanced programming patterns, possibly registering developer-provided “callback functions” within system-provided “event handlers”. Each callback would handle an asynchronous event that arises when an answer is ready. This kind of systems-level programming is powerful, but very error-prone, since it decomposes a high-level data flow into low-level system events that communicate through shared state. Sometimes this style is necessary, but here it is not.

Our program instead eschews that more cumbersome programming style for this more natural, *direct* style, where each request resembles an ordinary function call. This simpler, stylized programming form has become increasingly popular for expressing practical systems that interact with an *external environment*, as most modern software does today. However, it requires special compiler and type-system support, as we discuss in more detail below.

### Support for *asynchronous* behavior

In an *asynchronous* computing setting, a program and its running environment are permitted to perform *internal computations* that occur *concurrently* with one another.

Specifically, asynchronous programs are ones where the program’s requests of its environment do not (necessarily) require the program to wait for the environment. In the meantime, the program is permitted to make internal progress within this environment while the environment proceeds to complete the request. In the example, above, the program issues the second request before waiting for the first request to complete.

Symmetrically, the environment’s requests of the program do not (necessarily) require the environment to wait for the program’s answer: the environment can make external progress while the answer is produced.

We do not show an example of this “notify” pattern above, since it uses callbacks (and *higher-order* functions and control flow) and is thus more complex.

### Syntactic forms `async` and `await`

To address the need for clarity and simplicity, Motoko adopts the increasingly-common program constructs `async` and `await`, which afford the programmer a *structured* language for describing potentially-complex asynchronous dependency graphs.

The [async](language-manual.md#async) syntax introduces futures. A future value represents a *promise* of a result *that will be delivered, asynchronously, sometime in the future* (not shown in the first example above). You’ll learn more about futures when we introduce actors in [Actors and async data](actors-async.md).

Here, we merely use the ones that arise from calling `service1.computeAnswer(params)` and `service2.computeAnswer(params)`.

The syntax `await` synchronizes on a future, and suspends computation until the future is completed by its producer. We see two uses of `await` in the example above, to obtain the results from two calls to services.

When the developer uses these keywords, the compiler transforms the program as necessary, often doing complex transformations to the program’s control- and data-flow that would be tedious to perform by hand in a purely synchronous language. Meanwhile, the type system of Motoko enforces certain correct usage patterns for these constructs, including that types flowing between consumers and producers always agree, and that the types of data sent among services are permitted to flow there, and do not (for example) contain [private mutable state](mutable-state.md).

### Types are static

Like other modern programming languages, Motoko permits each variable to carry the value of a function, object, or a primitive datum (for example, a string, word, or integer). Other [types of values](basic-concepts.md#intro-values) exist too, including records, tuples, and “tagged data” called *variants*.

Motoko enjoys the formal property of type safety, also known as *type soundness*. We often summarize this idea with the phrase: [Well-typed Motoko programs don’t go wrong](basic-concepts.md#type-soundness), meaning that the only operations that will be performed on data are those permitted by its static type.

For example, each variable in a Motoko program carries an associated *type*, and this type is known *statically*, before the program executes. Each use of each variable is checked by the compiler to prevent runtime type errors, including null reference errors, invalid field access and the like.

In this sense, Motoko types provide a form of *trustworthy, **compiler-verified** documentation* in the program source code.

As usual, dynamic testing can check properties that are beyond the reach of the Motoko type system. While modern, the Motoko type system is intentionally *not* “advanced” or particularly exotic. Rather, the type system of Motoko integrates standard concepts from modern, but well-understood, [modern type systems](about-this-guide.md#modern-type-systems) to provide an approachable, expressive yet safe language for programming general-purpose, distributed applications.

-->
