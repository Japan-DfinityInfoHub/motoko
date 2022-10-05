# 基本的なコンセプトと用語

Motoko は、Actor を使った分散型プログラミングのために設計されています。

Internet Computer 上で Motoko を使ってプログラミングする場合、各 **Actor** は Motoko、Rust、Wasm、または Wasm にコンパイルされた他の言語など、その記述言語に関わらず、Candid インターフェースを持つ **Internet Computer Canister スマートコントラクト** を表します。Motoko 内では、Internet Computer にデプロイされる任意の言語で書かれた Canister を指すために **Actor** という用語を使用します。Motoko の役割は、これらの Actor を簡単に作成し、デプロイ後にプログラムで簡単に使用できるようにすることです。

Actor を使って分散型アプリケーションを書き始める前に、プログラミング言語の基本的な構成要素、特に Motoko について知っておく必要があります。 この章では、以降のドキュメントで使用されている、Motoko を使ったプログラミングを学ぶ上で欠かせない以下のような重要な概念や用語を紹介します：

- プログラム

- 宣言

- 式

- 値

- 変数

- 型

他の言語でのプログラミング経験がある方や、モダンプログラミング言語の理論に精通している方は、これらの用語やその使われ方に既に慣れていることでしょう。 これらの用語の使われ方は、Motoko でも特に変わった点はありません。 しかし、プログラミングに慣れていない方のために、このガイドでは、Actor や分散型プログラミングの使用を避けたシンプルなサンプルプログラムを用いて、これらの用語を徐々に紹介していきます。 基本的な用語を理解した後、言語のより高度な部分を学ぶことができます。 より高度な機能は、その複雑さに伴い、より複雑な例で説明されています。

この章では、以下のトピックについて説明します：

- [Motoko プログラムの構文](#motoko-program-syntax)

- [値の表示](#printing-values)

- [標準ライブラリの使い方](#the-motoko-base-library)

- [宣言と式](#declarations-versus-expressions)

- [変数の字句スコープ](#declarations-follow-lexical-scoping)

- [値と評価](#values-and-evaluation)

- [変数の型アノテーション](#type-annotations-and-variables)

- [型健全性と型安全な評価](#type-soundness)

## Motoko プログラムの構文

各 Motoko _プログラム_ は、宣言と式を自由に組み合わせたもので、それらの構文的な分類は異なりますが、互いに関連しています（プログラムの正確な構文については、[言語のクイックリファレンスガイド](language-manual.md)を参照して下さい）。

私たちが Internet Computer 上にデプロイするプログラムでは、有効なプログラムは *Actor 式*で構成されており、[Actor と async データ](actors-async.md)で説明するように、特定の構文(`actor` キーワード)が用いられます。

議論の準備として、本章と [ミュータブルなステート](mutable-state.md) の中で、Internet Computer の Service ではなく、Service を書くための Motoko のコードスニペットを用いて説明しています。それぞれは通常、（Service ではない） Motoko プログラムとして単独で実行することができ、場合によってはターミナルの出力をプリントすることもできます。

この章の例では、四則演算などの簡単な式を使って、Motoko の基本原理を説明します。 Motoko の全ての式の構文について知りたい方は、[言語のクイックリファレンス](language-manual.md)を参照してください。

まず初めに、次のコードスニペットは、変数 `x` と `y` の 2 つの宣言で構成されており、続く式で 1 つのプログラムを形成しています：

```motoko
let x = 1;
let y = x + 1;
x * y + x;
```

以下の議論では、この小さなプログラムの変形を使用します。

まず、このプログラムの型は `Nat`（自然数）であり、実行すると `3` という自然数の値に評価されます。

中括弧で囲まれたブロック（`do {` と `}`）と別の変数（`z`）を導入することで、元のプログラムを次のように修正することができます：

```motoko
let z = do {
  let x = 1;
  let y = x + 1;
  x * y + x
};
```

## 宣言と式

宣言は、イミュータブル（不変）な変数、ミュータブル（可変）なステート、Actor、オブジェクト、クラス、その他の型を導入します。 式は、これらを使った計算を記述します。

ここでは、イミュータブルな変数を宣言し、簡単な演算を行うプログラムを例に説明します。

### 宣言と式の違い

各 Motoko _プログラム_ は、宣言と式を自由に組み合わせたもので、それらの構文的な分類は異なるものの互いに関連しているということを[思い出しましょう](#motoko-program-syntax)。 この章では、例を使って宣言と式の区別を説明し、それらを混在させて使うことに慣れていきます。

上で最初に紹介したサンプルプログラムを思い出しましょう：

```motoko
let x = 1;
let y = x + 1;
x * y + x;
```

実際のところ、このプログラムは以下の _3_ 個の宣言からなる _宣言のリスト_ です：

1.  宣言 `let x = 1;` によるイミュータブルな変数 `x` と、

2.  宣言 `let y = x + 1;` によるイミュータブルな変数 `y` と、

3.  最終的な式の値である `x * y + x` を保持する _匿名の 暗黙的変数_。

この式 `x * y + x` は、より一般的な原理を示しています。 それぞれの式は、その式の結果の値で無名変数を暗黙的に宣言しているので、必要に応じて宣言と考えることができます。

式が最後の宣言として現れる場合、式は任意の型を持つことができます。ここでは、式 `x * y + x` の型は `Nat` です。

式が宣言リストの最後ではなく、宣言リストの中にある場合は、式はユニット型 `()` でなければなりません。

### 宣言リストにおけるユニット型でない式の無視

このユニット型でなければならないという制限は、`ignore` を明示的に使用して、使用されていない結果の値を無視することで切り抜けることができます。 例えば、以下のようになります：

```motoko
let x = 1;
ignore(x + 42);
let y = x + 1;
ignore(y * 42);
x * y + x;
```

### 宣言と変数の代入

宣言は相互再帰可能ですが、そうでない書き方のために代入セマンティクスを使うことができます（高校数学における式の単純化でおなじみの、等式を別の等式に代入すること。)

元の例を思い出してみましょう：

```motoko
let x = 1;
let y = x + 1;
x * y + x;
```

変数の宣言値をそれぞれの出現箇所に _代入_ することで、上のプログラムを手動で書き換えることができます。 そうすることで次のような式になり、これも有効なプログラムです。

```motoko
1 * (1 + 1) + 1
```

上の式も、元のプログラムと同じ型で、同じ動作（結果値 `3`）をする有効なプログラムです。 また、ブロックを使って一つの式を形成することもできます。

### 宣言からブロック式への変換

上記のプログラムの多くは、先ほどの例のように宣言のリストで構成されています：

```motoko
let x = 1;
let y = x + 1;
x * y + x
```

宣言リストそれ自体は _式_ ではないので、その最終値（`3`）を使って別の変数を（すぐに）宣言することはできません。

**ブロック式**：この宣言リストを _中括弧_ で囲むことで、_ブロック式_ を形成することができます。ブロックは、`if`、`loop`、`case` などの制御フローのサブ式としてのみ使用できます。それ以外の場所では、`do { …​ }` を使ってブロック式を表現し、ブロックをオブジェクトリテラルと区別しています。例えば、`do {}` は `()` 型の空のブロックで、`{}` は `{}` 型の空のレコードです。

```motoko
do {
  let x = 1;
  let y = x + 1;
  x * y + x
}
```

これも有効なプログラムですが、宣言された変数 `x` と `y` が、導入したブロック内のプライベートスコープになっています。

このブロック形式は、宣言リストとその _変数名の選択_ の自律性を維持するのに役立ちます。

ブロック式は値を生成し、括弧で囲むとより大きな複合式の中に出現させることができます。

```motoko
100 +
  (do {
     let x = 1;
     let y = x + 1;
     x * y + x
   })
```

### 宣言は **字句スコープ** に従う

上の例では、ブロックを入れ子にすることで、それぞれの宣言リストとその変数名の選択の自律性が保たれることを説明しました。 言語理論家はこの考え方を _字句スコープ_ と呼んでいます。 つまり、変数のスコープはネストしても構わないが、ネストする際に干渉してはいけないということです。

例えば、次の（ブロックの外の）プログラムは、2 ではなく 42 と評価されます。なぜなら、最後の行で出現する `x` と `y` は、囲まれたブロック内の定義ではなく、_最初の行の_ 定義を参照しているからです。

```motoko
let x = 40; let y = 2;
ignore do {
  let x = 1;
  let y = x + 1;
  x * y + x
};
x + y
```

字句スコープを持たない他の言語では、このプログラムは異なる結果となるかもしれません。 しかし、モダンな言語では普遍的に字句スコープが好まれています。

数学的な明快さはさておき、字句スコープの実用的な利点は _安全性_ であり、組成的に安全なシステムを構築する際に使用されます。 具体的には、Motoko は非常に強力な構成上の特性を持っています。例えば、信頼していないプログラムの中に自分のプログラムを入れ子にしても、入れ子の外のプログラムが、あなたの変数を恣意的に異なる意味に再定義することはできません。

## 値と評価

ひとたび Motoko の式がプログラムの制御の（シングル）スレッドを受け取ると、_結果の値_ になるまで張り切って評価します。

その際、一般的には _環境側の制御スタック_ からの制御を放棄する前に、サブ式やサブルーチンに制御を渡します。

もしこの式が値の形式に到達しない場合、式は無限に評価され続けます。 後ほど再帰関数や命令型制御フローを紹介しますが、これらはいずれも終了しない処理を許容するものです。 ここでは、結果として値が得られる、終了するプログラムのみを考えます。

上の例では、自然数を生成する式に焦点を当てて説明しました。 言語のより広範な概要として、以下に他の値の形式について簡単にまとめます：

### プリミティブな値

Motoko では、以下のプリミティブな値の形式を利用することができます：

- ブール値 (`true` と `false`).

- 整数 (…​,`-2`, `-1`, `0`, `1`, `2`, …​) - 制限付き整数と _制限なし_ 整数

- 自然数 (`0`, `1`, `2`, …​) - 制限付き自然数と _制限なし_ 自然数

- テキスト値 - ユニコード文字の文字列

デフォルトでは、**整数** と **自然数** は _制限なし_ で、オーバーフローしません。 その代わり、いかなる有限の数にも対応できるように、伸長する表現を使用しています。

実用性の観点から、Motoko には、デフォルトの制限なし数値とは別に、整数や自然数の _制限付き_ の型も含まれています。 それぞれの制限付き数値の型は、固定長（`8`, `16`, `32`, `64` のいずれか）を持ち、それぞれに “オーバーフロー” の可能性があります。このイベントが発生するとエラーとなり、[プログラムはトラップします](#traps-due-to-faults)。

Motoko では、明示的に _ラッピング_ 操作（演算子の中の `%` 文字で示されます）を行う場合などの十分に定義された状況を除いて、チェック・キャッチできないオーバーフローはありません。 Motoko では、さまざまな数値表現を変換するためのプリミティブな組み込み関数が用意されています。

[言語のクイックリファレンス](language-manual.md)は、[プリミティブ型](language-manual.md#primitive-types)の完全なリストを提供しています。

### 非プリミティブな値

Motoko では、上記のプリミティブな値と型に加えて、ユーザー定義の型や、以下の非プリミティブな値の形式とそれに関連する型を利用することができます。

- [タプル](language-manual.md#tuple)（ユニット値である "空のタプル" を含む）

- [配列](language-manual.md#arrays)（イミュータブルな配列とミュータブルな配列の両方）

- [オブジェクト](language-manual.md#object)（匿名の順序なしフィールドとメソッドを含む）

- [バリアント](language-manual.md#variant-types)（名前付きコンストラクタとオプショナルのペイロード値を含む）

- [関数値](language-manual.md#functions)（[shared 関数](sharing.md)を含む）

- [Async 値](language-manual.md#async)（_promise_ や _future_ としても知られる）

- [エラー値](language-manual.md#error-type)（例外やシステム障害のペイロードを運ぶ）

これらの形式の使用については後の章で説明します。 プリミティブな値と非プリミティブな値の正確な言語定義については、[言語のクイックリファレンス](language-manual.md)を参照してください。

### **unit 型** vs `void型`

Motoko には `void` という名前の型はありません。 Java や C++ などの言語を使っていて、返り値の型が “void” だと思っている読者も多いと思いますが、代わりに `()` と書かれた _ユニット型_ を思い浮かべるようにしてみてください。

実用的には、`void` と同様に、ユニット値は一般的に表現上のコストがありません。

`void` 型とは異なり、ユニット値は _存在します_ が、`void` 型の返り値と同様、ユニット値は内部的には何の値も持たず、_情報_ は常にゼロです。

ユニット値を数学的に考えるもう一つの方法は、要素を持たないタプル（"nullary" ならぬ “zero-ary”）です。このようなプロパティを持つ値は 1 つしかないので、数学的に一意であり、よって実行時に表現する必要はありません。

### 自然数

この型のメンバは、通常の値である `0`, `1`, `2`, …​ で構成されていますが、数学のように `Nat` が特別な最大サイズに制限されることはありません。 これらの値のランタイム表現は任意の大きさの数値に対応しており、"オーバーフロー" を（ほぼ）不可能にしています。 （_ほぼ_ 不可能というのは、プログラムのメモリが足りなくなるのと同じことで、極端な状況下ではプログラムによっては常に起こりうることだからです。)

Motoko では、通常の算術演算が可能です。 例として、次のようなプログラムを考えてみましょう：

```motoko
let x = 42 + (1 * 37) / 12: Nat
```

このプログラムは `Nat` 型の値 `45` と評価されます。

## 型の健全性

各 Motoko の式に対して型チェックが行われることを、_正しく型付けされている_ と呼んでいます。Motoko の式の _型_ は、プログラムが実行されたときの将来の動作についての、言語から開発者への約束事の役割を果たします。

まず、正しく型付けされたプログラムは、未定義の動作をすることなく評価されます。 これには、`正しく型付けされたプログラムは間違いを起こさない` という言葉が当てはまります。 この言葉の深い意味を知らない人のために補足すると、意味のある（曖昧さのない）プログラムには厳密な（概念としての）空間があり、型システムはその空間の中に留まることを強制しているため、すべての正しく型付けされたプログラムは、正確な（曖昧さのない）意味を持っているということです。

さらに言えば、型はプログラムの結果を正確に予測します。 制御を得れば、プログラムは元のプログラムの結果の型と一致する _結果の値_ を生成します。

いずれにしても、プログラムの静的な見方と動的な見方は、静的な型システムによってリンクされ、互いに一致します。 この静的な見方と動的な見方の一致は静的な型システムの中心的な原理であり、設計の中核的な側面として Motoko によって提供されています。

この型システムは、非同期のインタラクションがプログラムの静的・動的な見方が一致していること、そして "ボンネットの下で（内部で）" 生成された結果のメッセージが実行時に不一致にならないことも強制します。 この一致は、型付けされた言語で通常期待される、呼び出し元と呼び出された側の引数の型や返り値の型が一致することと、その精神が似ています。

## 型アノテーションと変数

変数は、（静的な）名前や（静的な）型と、実行時にのみ存在する（動的な）値を関連付けます。

この意味で、Motoko の型は、プログラムのソースコードの中で、_コンパイラが検証した信頼できるドキュメント_ を提供します。

以下の非常に短いプログラムを考えてみましょう：

```motoko
let x : Nat = 1
```

この例では、コンパイラは式 `1` が `Nat` 型であり、`x` も同じ型であることを推定します。

この場合、プログラムの意味を変えることなく、この型アノテーションを省略することができます：

```motoko
let x = 1
```

演算子のオーバーロードを伴うような難解な状況を除いて、型アノテーションは（通常は）実行中のプログラムの意味に影響を与えません。

型アノテーションが省略された状態でコンパイルが通った場合、上記のケースのように、プログラムは元のプログラムと同じ意味（同じ _動作_ ）となります。

しかし、コンパイラが他の前提条件を推測したり、プログラム全体をチェックしたりするために、型アノテーションが必要になることがあります。

型アノテーションを追加してもコンパイルが通る場合、追加された型アノテーションは既存の型アノテーションと _矛盾がない_ ことがわかります。

例えば、（必須ではない）型アノテーションを追加することで、コンパイラはすべての型アノテーションと他の推論された事実が全体として一致していることをチェックします。

```motoko
let x : Nat = 1 : Nat
```

しかし、アノテーションの型と _矛盾すること_ をしようとすると、タイプチェッカーはエラーを知らせます。

以下のような、正しく型付けされていないプログラムを考えましょう：

```motoko run
let x : Text = 1 + 1
```

`1 + 1` の型は `Nat` であって `Text` ではなく、また `Nat` と `Text` はサブタイプの関係にないので、型アノテーションの `Text` はその後のプログラムと一致しません。 結果的に、このプログラムは正しく型付けされておらず、コンパイラはエラーメッセージとエラー箇所を知らせ、コンパイルも実行もしません。

## 型のエラーとメッセージ

数学的には、Motoko の型システムは _宣言的_ であり、形式論理の概念として実装とは無関係に存在しています。 同様に、言語定義の他の重要な側面（例：実行セマンティクス）も、実装の外に存在しています。

しかし、この論理定義を設計し、試し、間違いを犯す練習をするために、私たちはこの型システムと対話し、その過程でたくさんの無害な間違いを犯したいのです。

_タイプチェッカー_ のエラーメッセージは、開発者が型システムの論理を誤解したり、あるいは適用を誤ったりしたときに開発者を助けようとするもので、本書では間接的に説明されています。

これらのエラーメッセージは時間の経過とともに改善されていくため、このドキュメントでは特定のエラーメッセージを記載していません。 その代わりに、各コード例をその周辺の文章で説明するようにしています。

### Motoko 標準ライブラリの使い方

言語のエンジニアリングにおけるさまざまな実用上の理由から、Motoko の設計では組み込みの型や操作を最小限に抑えるようにしています。

その代わり、Motoko 標準ライブラリは、言語を完全なものにするための型や操作を可能な限り提供しています。 **\*ただし**、この標準ライブラリは開発中であり、まだ不完全です。\*

[Motoko 標準ライブラリ](base-intro.md)では、Motoko 標準ライブラリからのモジュールを _選定して_ 示していますが、これは例題で使われているコアな機能に焦点を当てたもので、抜本的な変更はないと考えられます。 しかし、これらの標準ライブラリの API はすべて時間の経過とともに（程度の差こそあれ）確実に変化し、特にサイズと数が大きくなっていくでしょう。

標準ライブラリからインポートするには、`import` キーワードを使います。 導入するローカルモジュールの名前、この例では “**D**ebug” を表す `D` と、`import` 宣言がインポートされたモジュールを見つけるための URL を指定します。

```motoko file=./examples/print.mo

```

ここでは、Motoko のコードを（他のモジュール形式ではなく）、`mo:` という接頭辞でインポートします。 `base/` のパスを指定し、その後にモジュールのファイル名 `Debug.mo` から拡張子を除いたものを指定します。

### 値の出力

上の例では、ライブラリ `Debug.mo` の関数 `print` を使ってテキスト文字列を出力しています：

```motoko no-repl
print: Text -> ()
```

`print` 関数は、入力として（`Text` 型の）テキストの文字列を受け取り、出力として（_ユニット型_ または `()` の） _ユニット値_ を生成します。

ユニット値は情報を持たないので、ユニット型の値はすべて同一であり、`print` 関数は実際には何の結果も生み出しません。結果の代わりに _副作用_ を伴います。 `print` 関数は、人間が読める形式のテキスト文字列を出力端末に出力するという効果があります。出力したり、ステートを変更したりするような副作用のある関数は、しばしば _非純粋関数_ と呼ばれます。一方、副作用を伴わずに値を返すだけの関数は、_純粋関数_ と呼ばれます。 返り値（ユニット値）については[以下で詳しく](#the-unit-type)説明し、`void` 型のコンセプトに慣れている読者のために、`void` 型との関連性についても述べます。

最後になりますが、ほとんどの Motoko の値はデバッグ用に人間が読めるテキスト文字列に変換することができ、それらの変換を自分で書く必要は _ありません_ 。

`debug_show` プリミティブは、大規模なクラスの値を `Text` 型の値に変換することができます。

例えば、（`(Text, Nat, Text)` 型の）トリプルを、独自の変換関数を自分で書かずに、デバッグ用のテキストに変換することができます：

```motoko
import D "mo:base/Debug";
D.print(debug_show(("hello", 42, "world")))
```

これらのテキスト変換を使用して、プログラムを試す際にほとんどの Motoko データを出力することができます。

### 不完全なコードへの対応

プログラムを書いている最中に、完成前のコードや、いくつかの実行パスが見つからないか無効な状態のコードを実行したいと思うことがあります。

このような状況に対応するために、標準ライブラリである `Prelude` の `xxx`, `nyi`, `unreachable` 関数を、後述のように使用することができます。 それぞれの関数は、以下に説明する [一般的なトラップメカニズム](#explicit-traps) をラップしています。

### 短期的な穴を埋める

プログラム上に開いた短期的な穴（式の欠落）は、ソースリポジトリにコミットされることはなく、まだプログラムを書いている開発者の開発セッションでのみ存在します。

次のように Prelude をインポートしていたと仮定します：

```motoko name=prelude
import P "mo:base/Prelude";
```

開発者は、次のようにして _欠けている式_ を埋めることができます：

```motoko include=prelude
P.xxx()
```

その結果、この式が実行された場合には、コンパイル時に _常に_ 型チェックが行われ、実行時に _常に_ トラップが行われます。

### 長期的な穴を文書化する

慣習的に、長期的な穴は「まだ実装されていない」（`nyi: not yet implimented`）機能とみなされ、Prelude モジュールの似たような関数を使ってマークすることができます。

```motoko include=prelude
P.nyi()
```

### `到達不可能な` コードパスを文書化する

上記の状況とは対照的に、プログラムの不変条件における内部論理の一貫性を仮定すると、 コードが評価されることが _決してない_ ので、コードは _決して埋められない_ という場面もあります。

コードパスを、論理的に不可能あるいは _到達不可能_ なものとして記録するには、標準ライブラリの関数である `unreachable` を使います：

```motoko include=prelude
P.unreachable()
```

上記の状況と同様に、この関数はいかなる前後関係でも型チェックを行い、評価されるといかなる前後関係でもトラップを行います。

### 実行の失敗によるトラップ

ゼロ除算、配列の範囲外へのアクセス、パターンマッチの失敗などのエラーは型システムでは防ぐことができませんが、実行時に _トラップ_ と呼ばれるエラーを引き起こす可能性があります。

```motoko
1/0; // ゼロ除算によるトラップ
```

```motoko
    let a = ["hello", "world"];
    a[2]; // 配列の範囲外へのアクセスによるトラップ
```

```motoko
    let true = false; // パターンマッチの失敗
```

コードの実行がトラップを引き起こしたとき、コードが _トラップした_ と言います。

コードの実行は最初のトラップで中断され、以降は実行されません。

:::note

Actor メッセージ内で発生するトラップは少し微妙です。Actor 全体を中止するのではなく、特定のメッセージの進行を妨げ、まだコミットされていないステートの変更をロールバックします。Actor 上の他のメッセージは実行を継続します。

:::

### 明示的なトラップ

ときどき、ユーザーが定義したメッセージを用いて、無条件にトラップを強制することが有用な場合があります。

`Debug` ライブラリでは、この目的のために、`trap(t)` 関数を提供しており、どのような文脈においても使うことができます。

```motoko
import Debug "mo:base/Debug";

Debug.trap("oops!");
```

```motoko
import Debug "mo:base/Debug";

let swear : Text = Debug.trap("oh my!");
```

（前述の `Prelude` 関数の `nyi()`、`unreachable()`、`xxx()` は、`Debug.trap` の単純なラッパーです。）

### アサーション

アサーションでは、あるブール値のテストが成立しなかったときに条件付きでトラップし、成立する場合は実行を継続することができます。例えば、以下のようになります：

```motoko
    let n = 65535;
    assert n % 2 == 0; // n が偶数ではない場合にトラップ
```

```motoko
    assert false; // 無条件にトラップ
```

```motoko
    import Debug "mo:base/Debug";

    assert 1 > 0; // トラップしない
    Debug.print "bingo!";
```

アサーションが成功して実行に移ることもあるため、`()` 型の値が期待される文脈でのみ使用することができます。

<!--

# Basic concepts and terms

Motoko is designed for distributed programming with actors.

When programming on the Internet Computer in Motoko, each **actor** represents an **Internet Computer canister smart contract** with a Candid interface, whether written in Motoko, Rust, Wasm or some other language that compiles to Wasm. Within Motoko, we use the term **actor** to refer to any canister, authored in any language that deploys to the Internet Computer. The role of Motoko is to make these actors easy to author, and easy to use programmatically, once deployed.

Before you begin writing distributed applications using actors, you should be familiar with a few of the basic building blocks of any programming language and with Motoko in particular. To get you started, this section introduces the following key concepts and terms that are used throughout the remainder of the documentation and that are essential to learning to program in Motoko:

-   program

-   declaration

-   expression

-   value

-   variable

-   type

If you have experience programming in other languages or are familiar with modern programming language theory, you are probably already comfortable with these terms and how they are used. There’s nothing unique in how these terms are used in Motoko. If you are new to programming, however, this guide introduces each of these terms gradually and by using simplified example programs that eschew any use of actors or distributed programming. After you have the basic terminology as a foundation to build on, you can explore more advanced aspects of the language. More advanced features are illustrated with correspondingly more complex examples.

The following topics are covered in the section:

-   [Motoko program syntax](#motoko-program-syntax)

-   [Printing values](#printing-values)

-   [Using the base library](#the-motoko-base-library)

-   [Declarations versus expressions](#declarations-versus-expressions)

-   [Lexical scoping of variables](#declarations-follow-lexical-scoping)

-   [Values and evaluation](#values-and-evaluation)

-   [Type annotations and variables](#type-annotations-and-variables)

-   [Type soundness and type-safe evaluation](#type-soundness)

## Motoko program syntax

Each Motoko *program* is a free mix of declarations and expressions, whose syntactic classes are distinct, but related (see the [language quick reference](language-manual.md) for precise program syntax).

For programs that we deploy on the Internet Computer, a valid program consists of an *actor expression*, introduced with specific syntax (keyword `actor`) that we discuss in [Actors and async data](actors-async.md).

In preparing for that discussion, this section and Section [Mutable state](mutable-state.md) begin by discussing programs that are not meant to be Internet Computer services. Rather, these tiny programs illustrate snippets of Motoko for writing those services, and each can (usually) be run on its own as a (non-service) Motoko program, possibly with some printed terminal output.

The examples in this section illustrate basic principles using simple expressions, such as arithmetic. For an overview of the full expression syntax of Motoko, see the [Language quick reference](language-manual.md).

As a starting point, the following code snippet consists of two declarations — for the variables `x` and `y` — followed by an expression to form a single program:

``` motoko
let x = 1;
let y = x + 1;
x * y + x;
```

We will use variations of this small program in our discussion below.

First, this program’s type is `Nat` (natural number), and when run, it evaluates to the (natural number) value of `3`.

Introducing a block with enclosing braces (`do {` and `}`) and another variable (`z`), we can amend our original program as follows:

``` motoko
let z = do {
  let x = 1;
  let y = x + 1;
  x * y + x
};
```

## Declarations and expressions

Declarations introduce immutable variables, mutable state, actors, objects, classes and other types. Expressions describe computations that involve these notions.

For now, we use example programs that declare immutable variables, and compute simple arithmetic.

### Declarations versus expressions

[Recall](#motoko-program-syntax) that each Motoko *program* is a free mix of declarations and expressions, whose syntactic classes are distinct, but related. In this section, we use examples to illustrate their distinctions and accommodate their intermixing.

Recall our example program, first introduced above:

``` motoko
let x = 1;
let y = x + 1;
x * y + x;
```

In reality, this program is a *declaration list* that consists of *three* declarations:

1.  immutable variable `x`, via declaration `let x = 1;`,

2.  immutable variable `y`, via declaration `let y = x + 1;`,

3.  and an *unnamed, implicit variable* holding the final expression’s value, `x * y + x`.

This expression `x * y + x` illustrates a more general principle: Each expression can be thought of as a declaration where necessary since the language implicitly declares an unnamed variable with that expression’s result value.

When the expression appears as the final declaration, this expression may have any type. Here, the expression `x * y + x` has type `Nat`.

Expressions that do not appear at the end, but rather *within* the list of declarations must have unit type `()`.

### Ignoring non-unit-typed expressions in declaration lists

We can always overcome this unit-type restriction by explicitly using `ignore` to ignore any unused result values. For example:

``` motoko
let x = 1;
ignore(x + 42);
let y = x + 1;
ignore(y * 42);
x * y + x;
```

### Declarations and variable substitution

Declarations can be mutually recursive, but in cases where they are not, they permit substitution semantics. (that is, replacing equals for equals, as familiar from high-school algebraic simplification).

Recall our original example:

``` motoko
let x = 1;
let y = x + 1;
x * y + x;
```

We can manually rewrite the program above by *substituting* the variables' declared values for each of their respective occurrences.

In so doing, we produce the following expression, which is also a program:

``` motoko
1 * (1 + 1) + 1
```

This is also a valid program — of the same type and with the same behavior (result value `3`) — as the original program.

We can also form a single expression using a block.

### From declarations to block expressions

Many of the programs above each consist of a list of declarations, as with this example, just above:

``` motoko
let x = 1;
let y = x + 1;
x * y + x
```

A declaration list is not itself (immediately) an *expression*, so we cannot (immediately) declare another variable with its final value (`3`).

**Block expressions.** We can form a *block expression* from this list of declarations by enclosing it with matching *curly braces*. Blocks are only allowed as sub-expressions of control flow expressions like `if`, `loop`, `case`, etc. In all other places, we use `do { …​ }` to represent block expression, to distinguish blocks from object literals. For example, `do {}` is the empty block of type `()`, while `{}` is an empty record of record type `{}`.

``` motoko
do {
  let x = 1;
  let y = x + 1;
  x * y + x
}
```

This is also program, but one where the declared variables `x` and `y` are privately scoped to the block we introduced.

This block form preserves the autonomy of the declaration list and its *choice of variable names*.

A block expression produces a value and, when enclosed in parentheses, can occur within some larger, compound expression. For example:

``` motoko
100 +
  (do {
     let x = 1;
     let y = x + 1;
     x * y + x
   })
```

### Declarations follow **lexical scoping**

Above, we saw that nesting blocks preserves the autonomy of each separate declaration list and its *choice of variable names*. Language theorists call this idea *lexical scoping*. It means that variables' scopes may nest, but they may not interfere as they nest.

For instance, the following (larger, enclosing) program evaluates to `42`, *not* `2`, since the final occurrences of `x` and `y`, on the final line, refer to the *very first* definitions, *not* the later ones within the enclosed block:

``` motoko
let x = 40; let y = 2;
ignore do {
  let x = 1;
  let y = x + 1;
  x * y + x
};
x + y
```

Other languages that lack lexical scoping may give a different meaning to this program. However, modern languages universally favor lexical scoping, the meaning given here.

Aside from mathematical clarity, the chief practical benefit of lexical scoping is *security*, and its use in building compositionally-secure systems. Specifically, Motoko gives very strong composition properties. For example, nesting your program within a program you do not trust cannot arbitrarily redefine your variables with different meanings.

## Values and evaluation

-->
<!--
TODO: retitle and improve
-->
<!--

Once a Motoko expression receives the program’s (single) thread of control, it evaluates eagerly until it reduces to a *result value*.

In so doing, it will generally pass control to sub-expressions, and to sub-routines before it gives up control from the *ambient control stack*.

If this expression never reaches a value form, the expression evaluates indefinitely. Later we introduce recursive functions and imperative control flow, which each permit non-termination. For now, we only consider terminating programs that result in values.

In the material above, we focused on expressions that produced natural numbers. As a broader language overview, however, we briefly summarize the other value forms below:

### Primitive values

Motoko permits the following primitive value forms:

-   Boolean values (`true` and `false`).

-   Integers (…​,`-2`, `-1`, `0`, `1`, `2`, …​) - bounded and *unbounded* variants.

-   Natural numbers (`0`, `1`, `2`, …​) - bounded and *unbounded* variants.

-   Text values - strings of unicode characters.

By default, **integers** and **natural numbers** are *unbounded* and do not overflow. Instead, they use representations that grow to accommodate any finite number.

For practical reasons, Motoko also includes *bounded* types for integers and natural numbers, distinct from the default versions. Each bounded variant has a fixed bit-width (one of `8`, `16`, `32`, `64`) that determines the range of representable values and each carries the potential for *overflow*. Exceeding a bound is a run-time fault that causes the program to [trap](#traps-due-to-faults).

There are no unchecked, uncaught overflows in Motoko, except in well-defined situations, for explicitly *wrapping* operations (indicated by a conventional `%` character in the operator). The language provides primitive built-ins to convert between these various number representations.

The [language quick reference](language-manual.md) contains a complete list of [primitive types](language-manual.md#primitive-types).

### Non-primitive values

-->
<!--
TODO: records and modules, improve
-->
<!--

Building on the primitive values and types above, the language permits user-defined types, and each of the following non-primitive value forms and associated types:

-   [Tuples](language-manual.md#tuples), including the unit value (the "empty tuple");

-   [Arrays](language-manual.md#arrays), with both *immutable* and *mutable* variants;

-   [Objects](language-manual.md#objects), with named, unordered fields and methods;

-   [Variants](language-manual.md#variant-types), with named constructors and optional payload values;

-   [Function values](language-manual.md#functions), including [shareable functions](sharing.md);

-   [Async values](language-manual.md#async), also known as *promises* or *futures*;

-   [Error values](language-manual.md#error-type) carry the payload of exceptions and system failures.

We discuss the use of these forms in the next sections.

For precise language definitions of primitive and non-primitive values, see the [language quick reference](language-manual.md).

### The *unit* type `()`

Motoko has no type named `void`. In many cases where readers may think of return types being “void” from using languages like Java or C++, we encourage them to think instead of the *unit type*, written `()`.

In practical terms, like `void`, the unit value usually carries zero representation cost.

Unlike the `void` type, there *is* a unit value, but like the `void` return value, the unit value carries no values internally, and as such, it always carries zero *information*.

Another mathematical way to think of the unit value is as a tuple with no elements - the nullary (“zero-ary”) tuple. There is only one value with these properties, so it is mathematically unique, and thus need not be represented at runtime.

### Natural numbers

The members of this type consist of the usual values - `0`, `1`, `2`, …​ - but, as in mathematics, the members of `Nat` are not bound to a special maximum size. Rather, the runtime representation of these values accommodates arbitrary-sized numbers, making their "overflow" (nearly) impossible. (*nearly* because it is the same event as running out of program memory, which can always happen for some programs in extreme situations).

Motoko permits the usual arithmetic operations one would expect. As an illustrative example, consider the following program:

``` motoko
let x = 42 + (1 * 37) / 12: Nat
```

This program evaluates to the value `45`, also of type `Nat`.

## Type soundness

Each Motoko expression that type-checks we call *well-typed*. The *type* of a Motoko expression serves as a promise from the language to the developer about the future behavior of the program, if executed.

First, each well-typed program will evaluate without undefined behavior. That is, the phrase **“well-typed programs don’t go wrong”** applies here. For those unfamiliar with the deeper implications of that phrase, it means that there is a precise space of meaningful (unambiguous) programs, and the type system enforces that we stay within it, and that all well-typed programs have a precise (unambiguous) meaning.

Furthermore, the types make a precise prediction over the program’s result. If it yields control, the program will generate a *result value* that agrees with that of the original program.

In either case, the static and dynamic views of the program are linked by and agree with the static type system. This agreement is the central principle of a static type system, and is delivered by Motoko as a core aspect of its design.

The same type system also enforces that asynchronous interactions agree between static and dynamic views of the program, and that the resulting messages generated "under the hood" never mismatch at runtime. This agreement is similar in spirit to the caller/callee argument type and return type agreements that one ordinarily expects in a typed language.

## Type annotations and variables

Variables relate (static) names and (static) types with (dynamic) values that are present only at runtime.

In this sense, Motoko types provide a form of *trusted, compiler-verified documentation* in the program source code.

Consider this very short program:

``` motoko
let x : Nat = 1
```

In this example, the compiler infers that the expression `1` has type `Nat`, and that `x` has the same type.

In this case, we can omit this annotation without changing the meaning of the program:

``` motoko
let x = 1
```

Except for some esoteric situations involving operator overloading, type annotations do not (typically) affect the meaning of the program as it runs.

If they are omitted and the compiler accepts the program, as is the case above, the program has the same meaning (same *behavior*) as it did originally.

However, sometimes type annotations are required by the compiler to infer other assumptions, and to check the program as a whole.

When they are added and the compiler still accepts the program, we know that the added annotations are *consistent* with the existing ones.

For instance, we can add additional (not required) annotations, and the compiler checks that all annotations and other inferred facts agree as a whole:

``` motoko
let x : Nat = 1 : Nat
```

If we were to try to do something *inconsistent* with our annotation type, however, the type checker will signal an error.

Consider this program, which is not well-typed:

``` motoko run
let x : Text = 1 + 1
```

The type annotation `Text` does not agree with the rest of the program, since the type of `1 + 1` is `Nat` and not `Text`, and these types are unrelated by subtyping. Consequently, this program is not well-typed, and the compiler will signal an error (with a message and location) and will not compile or execute it.

## Type errors and messages

Mathematically, the type system of Motoko is *declarative*, meaning that it exists independently of any implementation, as a concept entirely in formal logic. Likewise, the other key aspects of the language definition (for example, its execution semantics) exist outside of an implementation.

However, to design this logical definition, to experiment with it, and to practice making mistakes, we want to interact with this type system, and to make lots of harmless mistakes along the way.

The error messages of the *type checker* attempt to help the developer when they misunderstand or otherwise misapply the logic of the type system, which is explained indirectly in this book.

These error messages will evolve over time, and for this reason, we will not include particular error messages in this text. Instead, we will attempt to explain each code example in its surrounding prose.

### The Motoko base library

-->
<!--
TODO: replace library by package
-->
<!--

For various practical language engineering reasons, the design of Motoko strives to minimize builtin types and operations.

Instead, whenever possible, the Motoko base library provides the types and operations that make the language feel complete. ***However**, this base library is still under development, and is still incomplete*.

The [Motoko Base Library](./base-intro.md) lists a *selection* of modules from the Motoko base library, focusing on core features used in the examples that are unlikely to change radically. However, all of these base library APIs will certainly change over time (to varying degrees), and in particular, they will grow in size and number.

To import from the base library, use the `import` keyword. Give a local module name to introduce, in this example `D` for “**D**ebug”, and a URL where the `import` declaration may locate the imported module:

``` motoko file=./examples/print.mo
```

In this case, we import Motoko code (not some other module form) with the `mo:` prefix. We specify the `base/` path, followed by the module’s file name `Debug.mo` minus its extension.

### Printing values

Above, we print the text string using the function `print` in library `Debug.mo`:

``` motoko no-repl
print: Text -> ()
```

The function `print` accepts a text string (of type `Text`) as input, and produces the *unit value* (of *unit type*, or `()`) as its output.

Because unit values carry no information, all values of type unit are identical, so the `print` function doesn’t actually produce an interesting result. Instead of a result, it has a *side effect*. The function `print` has the effect of emitting the text string in a human-readable form to the output terminal. Functions that have side effects, such as emitting output, or modifying state, are often called *impure*. Functions that just return values, without further side-effects, are called *pure*. We discuss the return value (the unit value) [in detail below](#the-unit-type), and relate it to the `void` type for readers more familiar with that concept.

Finally, we can transform most Motoko values into human-readable text strings for debugging purposes, *without* having to write those transformations by hand.

The `debug_show` primitive permits converting a large class of values into values of type `Text`.

For instance, we can convert a triple (of type `(Text, Nat, Text)`) into debugging text without writing a custom conversion function ourselves:

``` motoko
import D "mo:base/Debug";
D.print(debug_show(("hello", 42, "world")))
```

Using these text transformations, we can print most Motoko data as we experiment with our programs.

### Accommodating incomplete code

Sometimes, in the midst of writing a program, we want to run an incomplete version, or a version where one or more execution paths are either missing or simply invalid.

To accommodate these situations, we use the `xxx`, `nyi` and `unreachable` functions from the base `Prelude` library, explained below. Each is a simple wrapper around a more general trap mechanism [general trap mechanism](#explicit-traps), explained further below.

### Use short-term holes

Short-term holes are never committed to a source repository, and only ever exist in a single development session, for a developer that is still writing the program.

Assuming that earlier, one has imported the prelude as follows:

``` motoko name=prelude
import P "mo:base/Prelude";
```

The developer can fill *any missing expression* with the following one:

``` motoko include=prelude
P.xxx()
```

The result will *always* type check at compile time, and *will always* trap at run time, if and when this expression ever executes.

### Document longer-term holes

By convention, longer-term holes can be considered "not yet implemented" (`nyi`) features, and marked as such with a similar function from the Prelude module:

``` motoko include=prelude
P.nyi()
```

### Document `unreachable` code paths

In contrast to the situations above, sometimes code will *never* be filled, since it will *never* be evaluated, assuming the coherence of the internal logic of the programs' invariants.

To document a code path as logically impossible, or *unreachable*, use the base library function `unreachable`:

``` motoko include=prelude
P.unreachable()
```

As in the situations above, this function type-checks in all contexts, and when evaluated, traps in all contexts.

-->
<!--
TODO: add more general intro to traps, including section on prelude functions, reference that instead
-->
<!--

### Traps due to faults

Some errors, such as division by zero, out-of-bounds array indexing, and pattern match failure are (by design) not prevented by the type system, but instead cause dynamic faults called *traps*.

``` motoko
1/0; // traps due to division by 0
```

``` motoko
let a = ["hello", "world"];
a[2]; // traps due to out-of-bounds indexing
```

``` motoko
let true = false; // pattern match failure
```

We say that code *traps* when its exection causes a *trap*.

Because the meaning of execution is ill-defined after a faulting trap, execution of the code ends by aborting at the trap.

:::note

Traps that occur within actor messages are more subtle: they don’t abort the entire actor, but prevent that particular message from proceeding, rolling back any yet uncommitted state changes. Other messages on the actor will continue execution.

:::

### Explicit traps

Occasionally it can be useful to force an unconditional trap, with a user-defined message.

The `Debug` library provides the function `trap(t)` for this purpose, which can be used in any context.

``` motoko
import Debug "mo:base/Debug";

Debug.trap("oops!");
```

``` motoko
import Debug "mo:base/Debug";

let swear : Text = Debug.trap("oh my!");
```

(The `Prelude` functions `nyi()`, `unreachable()` and `xxx()` discussed above are simple wrappers around `Debug.trap`.)

### Assertions

Assertions allow you to conditionally trap when some Boolean test fails to hold, but continue execution otherwise. For example,

``` motoko
let n = 65535;
assert n % 2 == 0; // traps when n not even
```

``` motoko
assert false; // unconditionally traps
```

``` motoko
import Debug "mo:base/Debug";

assert 1 > 0; // never traps
Debug.print "bingo!";
```

Because an assertion may succeed, and thus proceed with execution, it may only be used in context where a value of type `()` is expected.

-->
