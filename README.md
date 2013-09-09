# NicoCui

ニコ動のマイページに表示されるニコレポから公式放送の動画をパトロールするスクリプト。

## Installation

```
$ git clone https://github.com/gosyujin/nico_cui.git
```

## Usage

- pit を使ってアカウントを登録しているため pit ファイルに以下の情報を追加する

```
1 ---
2 nico:
3  id: メールアドレス
4  password: パスワード
```

1. bundle install する
1. ruby lib/nico_cui.rb すると以下のファイルが `./download` に落ちてくる( `_config.yml` で変更可能)
  - 動画ファイル
  - コメントxmlファイル
  - descriptionとかタグとかまとまったhtmlファイル
1. 動画ファイルとコメントファイルを同じディレクトリに置いて、Nicofoxとかで再生するとコメントも再生される

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
