# （非公式） Dfinity ドキュメント翻訳プロジェクト

本リポジトリは、[こちら](https://github.com/Japan-DfinityInfoHub/docs)で実施している Dfinity ドキュメント翻訳プロジェクトの子リポジトリです。

> Dfinity 公式ドキュメントは、[dfinity/docs](https://github.com/dfinity/docs) のリポジトリに全てのドキュメントファイルが集約されているわけではなく、[dfinity/motoko](https://github.com/dfinity/motoko) などの他のリポジトリに置かれた AsciiDoc ファイルが集約されて一つのドキュメントとなっています。

本リポジトリでは、[dfinity/motoko](https://github.com/dfinity/motoko) のドキュメントを翻訳しています。

## 翻訳手順

翻訳の状況は、親リポジトリである Japan-DfinityInfoHub/docs の[翻訳の概要と進捗状況](https://github.com/Japan-DfinityInfoHub/docs/issues/17)の issues を確認してください。

### 手順 1: 翻訳を始める準備の準備

> [Japan-DfinityInfoHub/docs](https://github.com/Japan-DfinityInfoHub/docs) の手順 1 と同じです。
> 既に実施している方は飛ばしてください。

Dfinity のドキュメントは [AsciiDoc](https://azure.microsoft.com/ja-jp/products/visual-studio-code/) によって書かれており、[Antora](https://antora.org/) を用いてビルドされています。
ローカル環境でドキュメントをビルドして確認できるように、以下の手順で Antora をインストールします。

Antora のインストールには [Node](https://nodejs.org/ja/) が必要です。

Windows 10 の場合には [WSL2 上にインストール](https://docs.microsoft.com/ja-jp/windows/dev-environment/javascript/nodejs-on-wsl)することをお勧めします。

Mac OS の場合には [Homebrew でインストール](https://blog.proglus.jp/2004/)するのが良いと思います。

Node のインストールができたら、[Antora のインストール](https://docs.antora.org/antora/2.3/install/install-antora/)を行います。
ここではグローバル環境にインストールする手順を説明します。

```
$ npm i -g @antora/cli@2.3 @antora/site-generator-default@2.3
```

以下のコマンドでインストールできていることを確認します。

```
$ antora -v
```

`2.3.x` などのバージョン名が表示されれば OK です。

### 手順 2: 翻訳を始める準備

まずは、このリポジトリを右上から Fork してください。

そして、リポジトリをクローンします。`your` には、あなたの GitHub のユーザーネームを入れてください。

```
$ git clone https://github.com/your/motoko
$ cd motoko
```

翻訳作業を行うためのブランチを作成します。
どのファイルを翻訳するかは、Japan-DfinityInfoHub/docs の[翻訳の概要と進捗状況](https://github.com/Japan-DfinityInfoHub/docs/issues/17)の翻訳ページ一覧を確認して、翻訳したい箇所をコメントしてください。

ここでは、例として `language-guide/pages/motoko.adoc` を翻訳するためのブランチを作成します。

```
$ git checkout -b language-guide/pages/motoko.adoc
```

これで、翻訳を始める準備は完了です。エディタを使って、翻訳箇所のファイルを編集します。
今回の例の場合、ファイルの場所は、`./doc/modules/` に、上で示した `language-guide/pages/motoko.adoc` を足した、`./doc/modules/language-guide/pages/motoko.adoc` です。

### 手順 3: 翻訳

[スタイルガイド](https://github.com/Japan-DfinityInfoHub/docs/blob/main/styleguide.md)に目を通してください。
わからないことがあれば [Discord](https://discord.gg/ewAxzfTURX) の#ドキュメント翻訳チャネルで質問してください。

エディタとしては [VSCode](https://azure.microsoft.com/ja-jp/products/visual-studio-code/) を推奨します。
[AsciiDoc の拡張機能](https://marketplace.visualstudio.com/items?itemName=asciidoctor.asciidoctor-vscode)を入れると少し幸せになれるかもしれません。

### 手順 4: 翻訳内容の確認

翻訳した文章を確認するために、手順 1 で導入した Antora を用いてローカルビルドします。

```
$ antora local-antora-playbook.yml
```

のコマンドを叩くと、ビルドが実行されます。
ビルド後、`build/site/docs` 以下の html ファイルを直接開きます。

```
$ open build/site/docs/introduction/welcome.html
```

ブラウザが開き、翻訳が反映されていることが確認できます。

### 手順 5: 翻訳内容のプルリクを出す

翻訳が終わったら、ローカルリポジトリにコミットしたあと、自分のリモートリポジトリにプッシュします。
コミットが複数になった場合、なるべく[１つのコミットにまとめて](https://dev.classmethod.jp/articles/git-rebase-fixup/)いただければありがたいですが、難しければそのままでも OK です。

```
$ git add doc/modules/language-guide/pages/motoko.adoc
$ git commit -m "translated: language-guide/pages/motoko.adoc"
$ git push origin language-guide/pages/motoko.adoc
```

最後に、Github から[プルリクを出します](https://qiita.com/samurai_runner/items/7442521bce2d6ac9330b)。
このとき、出し先が Japan-DfinityInfoHub/motoko になるようにします。
間違えて本家の dfinity/motoko に出してしまわないように気をつけてください。

以上です！メンテナーがレビューをして問題なければマージされます。

# Motoko

# [Motoko](https://internetcomputer.org/docs/current/developer-docs/build/cdks/motoko-dfinity/motoko/) &middot; [![GitHub license](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![Tests](https://img.shields.io/github/workflow/status/dfinity/motoko/release?logo=github)](https://github.com/dfinity/embed-motoko/actions?query=workflow:"release") [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/dfinity/motoko/blob/master/Building.md)

A safe, simple, actor-based programming language for authoring [Internet Computer](https://internetcomputer.org/) (IC) canister smart contracts.

## User Documentation & Samples

- [Building, installing, and developing on Motoko](Building.md).
- [Overview](doc/md/overview.md).
- [Small samples](samples).
- [Language manual](doc/md/language-manual.md).
- [Concrete syntax](doc/md/examples/grammar.txt).
- [Documentation sources](doc/md/).
- [Base library documentation](doc/md/base/index.md).

## Introduction

### Motivation and Goals

- High-level language for programming IC applications

- Simple ("K.I.S.S.") design and familiar syntax for average programmers

- Good and convenient support for actor model

- Good fit for underlying Wasm and IC execution model

- Anticipate future extensions to Wasm where possible

### Key Design Points

- Simple class-based OO language, objects as closures

- Classes can be actors

- Async construct for direct-style programming of asynchronous messaging

- Structurally typed with simple generics and subtyping

- Overflow-checked number types, explicit conversions

- JavaScript/TypeScript-style syntax but without the JavaScript madness

- Inspirations from Java, C#, JavaScript, Swift, Pony, ML, Haskell

## Related repositories

- [Base library](https://github.com/dfinity/motoko-base)
- [Vessel package manager](https://github.com/dfinity/vessel)
- [Example projects](https://github.com/dfinity/examples/tree/master/motoko)
- [Motoko Playground](https://github.com/dfinity/motoko-playground) &middot; ([online IDE](https://m7sm4-2iaaa-aaaab-qabra-cai.ic0.app))
- [Embed Motoko code snippets](https://github.com/dfinity/embed-motoko) &middot; ([online interpreter](https://embed.smartcontracts.org/))
- [VS Code extension](https://github.com/dfinity/vscode-motoko) &middot; ([install](https://marketplace.visualstudio.com/items?itemName=dfinity-foundation.vscode-motoko))
- [Browser and Node.js bindings](https://github.com/dfinity/node-motoko) &middot; ([npm package](https://www.npmjs.com/package/motoko))

## Community resources

- [Awesome Motoko](https://github.com/motoko-unofficial/awesome-motoko#readme)
- [Motoko Bootcamp](https://github.com/motoko-bootcamp/bootcamp#readme) &middot; ([YouTube channel](https://www.youtube.com/channel/UCa7_xHjvOESf9v281VU4qVw))
- [Motoko library starter template](https://github.com/ByronBecker/motoko-library-template)
