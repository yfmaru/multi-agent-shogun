# GitHub CLI (gh) セットアップ手順（WSL2, sudoなし）

本環境（WSL2, Ubuntu系, bash）に `gh` CLIをsudoなしでユーザーローカルに導入した際の手順記録。
環境再構築時はこの手順を再現すればよい。

## 前提調査（導入前に確認した事実）

- `which gh` → 未検出（WSL2ネイティブのLinux版ghは未導入だった）
- Windows側には `C:\Program Files\GitHub CLI\gh.exe` が既に存在し、
  WSLの `$PATH` にも `/mnt/c/Program Files/GitHub CLI/` が含まれていたため
  `gh.exe` としては呼べる状態だった。ただし今回はWSLネイティブのLinux版を
  優先して別途導入した（Windows側のgh.exeは未使用のまま）。
- `~/.local/bin` は既に存在し、`$PATH` に含まれていた（`claude` コマンドの
  シンボリックリンクが既に置かれていたため）。
- `git config --get credential.helper` → 未設定（global/repoとも）。
  今回の作業ではcredential.helperの変更は一切行っていない。
- シェルは bash。`~/.bashrc` は存在するが、`~/.local/bin` が既にPATHに
  含まれていたため **rcファイルへの追記は不要だった**。

## 導入手順

1. 最新リリースのバージョンをGitHub APIから機械的に取得:
   ```bash
   curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
     | grep -m1 '"tag_name"'
   # → v2.96.0
   ```

2. tarballとchecksumファイルをファイルに保存（pipe-to-shell禁止のため、
   必ずダウンロード→検証→展開の順で行う）:
   ```bash
   curl -fsSL -o gh.tar.gz \
     "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_linux_amd64.tar.gz"
   curl -fsSL -o gh_checksums.txt \
     "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_checksums.txt"
   ```

3. チェックサム検証:
   ```bash
   grep "linux_amd64.tar.gz" gh_checksums.txt
   sha256sum gh.tar.gz
   # 両者が一致することを確認
   ```

4. アーカイブの中身を展開前に確認（構成が公式パッケージのレイアウト
   （LICENSE, share/man/…, bin/gh）であることを確認してから展開）:
   ```bash
   tar -tzf gh.tar.gz | head -30
   tar -tzf gh.tar.gz | grep 'bin/gh$'
   ```

5. 展開してユーザーローカルbinへ配置:
   ```bash
   mkdir -p ~/.local/bin
   tar -xzf gh.tar.gz -C /path/to/tmpdir
   cp /path/to/tmpdir/gh_2.96.0_linux_amd64/bin/gh ~/.local/bin/gh
   chmod +x ~/.local/bin/gh
   ```

6. 動作確認:
   ```bash
   ~/.local/bin/gh --version
   # gh version 2.96.0 (2026-07-02)
   which gh   # 新しいシェルで ~/.local/bin/gh が解決されることを確認
   ```

## PATH設定について

この環境では `~/.local/bin` が既に `$PATH` に含まれていたため、
`.bashrc` への追記は行っていない。もし別環境で `~/.local/bin` が
PATHに含まれない場合は、以下を `~/.bashrc` の末尾に**追記**すること
（既存内容は変更しない）:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 認証（主が別セッションで実行する範囲）

`gh auth login` は対話コマンド（ブラウザ/デバイスフロー）であり、
非対話シェルでは完遂できない。導入作業はここまでとし、認証は主が
別セッションで以下を実行する。

```
gh auth login
```

- `~/.local/bin` は本環境で既にPATHに含まれているため、上記コマンドを
  そのまま実行すればよい（`~/.local/bin/gh auth login` のようなフルパス
  指定は不要）。
- 認証完了後、`gh auth status` で認証済みであることを確認できる。
- credential.helper は本手順では変更していない。`gh auth login` の
  対話フローの中で `Authenticate Git with your GitHub credentials?` と
  問われた場合、`Yes` を選択すると `gh` が `git` の認証情報ヘルパーとして
  自動設定される（これによりoriginへのgit pushが可能になる）。

## workflow scope に関する教訓（cmd_163実体験）

- `gh auth login` のデバイスフロー認証はデフォルトで `workflow` scope を
  含まない。`.github/workflows/**` 配下へ push する必要がある場合は、
  別途 `gh auth refresh -s workflow` の実行が必要。
- `gh auth refresh` のような `gh` CLI コマンドを非対話・スクリプト文脈で
  実行する場合は `-h github.com` のホスト指定が必須。
- 本教訓は cmd_163 T2 で `.github/workflows/test.yml` を含む push が
  workflow scope 不足により失敗した実体験に基づく。
