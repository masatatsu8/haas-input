# 旧Haas版の合成ストア

voiceink-haas の `a3bc288cc9a643aa0dc9dae3570d3c5e588d679b` から取得した4モデルを、Swift module名 `VoiceInk`、Swift 5、macOS 15 targetでコンパイルして生成しました。実ユーザーデータは含みません。

`expected.json` は生成器に渡した明示的な入力です。新保存層の出力から期待値を作ってはいけません。`stores/` は旧版の別プロセスで全値の一致を確認済みです。テストはこのディレクトリのコピーだけを開きます。

再生成には `generation/` の旧ソースを使用します。生成器の引数は generation/FixtureRunner.swift を参照してください。元のストアを新モデルで開いて更新しないでください。架空の音声URLは保存文字列の互換確認用で、再生確認用ではありません。
