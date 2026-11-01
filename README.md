# Amcrest Viewer para Mac

App nativo do macOS (SwiftUI) para ver as câmeras **Amcrest** (e Dahua, que fabrica para a Amcrest) ao vivo.

Ele usa só os protocolos abertos que a própria câmera oferece:

- API HTTP (`/cgi-bin/...`)
- MJPEG
- RTSP

Não usa a nuvem nem o P2P da Amcrest, e não depende de bibliotecas externas.

## O que faz

- **Administração do hardware** (botão de engrenagem na barra, ou ⌘,): janela própria, separada da grade, com tudo que é cadastro e configuração:
  - **Câmeras**: lista com busca (nome, IP ou S/N), situação da senha, editar, abrir e remover (uma ou várias);
  - **Adicionar câmeras**: procurar na rede, por S/N, por IP ou importar `.txt`;
  - **Usuário e senha**: aplica o mesmo login a várias câmeras de uma vez (ex.: todas as sem senha);
  - **Hardware e firmware**: lê de cada câmera o modelo, a versão do firmware, o S/N e o hardware, e guarda o S/N no cadastro. Atualizar firmware pelo app vem depois.
  - **Versões**: versão instalada e o histórico de versões, com data e o que mudou (também no menu do app → "Versões e novidades…").
  A grade principal fica só para assistir (colunas e IA).
- **Procura câmeras na rede local** (Administração → Adicionar câmeras → "Procurar na rede"): o app faz uma busca pelo padrão aberto **ONVIF** (WS-Discovery) e, ao mesmo tempo, **varre toda a faixa de IP** da rede do Mac (o /24 de cada interface) pela API HTTP da câmera, o que acha também NVRs e câmeras com ONVIF desligado, lista o que respondeu com nome, IP e número de série, e você marca e adiciona num clique. É só broadcast na sua rede — **nada vai para a nuvem** e não usa o P2P da Amcrest. As câmeras já cadastradas aparecem marcadas, sem duplicar.
- **Adiciona por número de série (S/N)**: no cadastro, dá para deixar o **Endereço em branco** e informar só o **S/N**. O app procura a câmera na rede pelo S/N e preenche o IP sozinho (mesma descoberta ONVIF, sem nuvem). Precisa que a câmera esteja ligada e na mesma rede do Mac.
- **Importa a lista de câmeras de um `.txt`**, com uma câmera por linha. Veja o [`cameras.exemplo.txt`](cameras.exemplo.txt). As linhas que o app não entende aparecem com o número e o motivo, para você corrigir. Nada é adivinhado.
- **Grade ao vivo** com todas as câmeras, de 1 a 4 colunas, usando o subfluxo (leve).
- **Janela por câmera** (duplo clique), com:
  - qualidade alta ou leve;
  - **PTZ** (segure a seta para mover, zoom, velocidade e presets);
  - **snapshot**, salvo em `Imagens/Amcrest`;
  - **abrir no VLC**: RTSP principal, em alta qualidade e com áudio.
  - **presets com nome**: lista os presets salvos na câmera e grava a posição atual num número, com o nome que você digitar (o nome fica guardado no app);
  - **gravações do microSD**: escolha o dia, veja os vídeos (início, fim, duração, movimento ou contínua), assista ou baixe o `.dav` para `Filmes/Amcrest`. **Assistir precisa do [VLC](https://www.videolan.org/vlc/download-macos.html)** instalado; baixar funciona sem ele.
- **IA no seu Mac — detectar pessoas e veículos:** os botões "Detectar pessoas" e "Detectar veículos" na barra ligam a análise das imagens com o Vision da Apple. A câmera onde aparece alguém ganha um selo "Pessoa"; onde aparece um carro, caminhão, moto etc., um selo "Veículo". Tudo roda localmente, nada vai para a nuvem e não precisa baixar modelo.
- **Senhas no Keychain** do macOS. Nunca ficam em arquivo.
- **Testar conexão** no cadastro: mostra o modelo da câmera ou diz o que corrigir.
- **Se a câmera não oferecer MJPEG** naquele fluxo, o app passa a buscar snapshots (cerca de 1 por segundo) e avisa na tela ("snapshots ~1/s"), para ninguém confundir com vídeo contínuo.
- **Reconecta sozinho** se a rede cair. Se a senha estiver errada, para e pede a correção.

## Como rodar

Requisitos: macOS 13 ou mais recente e o Xcode 15 ou mais recente (ou só as Command Line Tools).

```bash
git clone https://github.com/paulocpjunior/amcrest-viewer-mac.git
cd amcrest-viewer-mac
swift run
```

Para gerar o app de verdade (`.app`) e instalar em Aplicativos:

```bash
./scripts/build-app.sh
mv "dist/Amcrest Viewer.app" /Applications/
```

Também dá para abrir a pasta no Xcode (`open Package.swift`) e rodar com ⌘R.

Na primeira vez, o macOS pergunta se o app pode acessar a **rede local**. Responda **Permitir**.

## Formato do `.txt`

```
# comentário
Garagem 192.168.1.10
Portão, 192.168.1.11:8080, admin
Quintal = cam-quintal.local
NVR sala 192.168.1.50 canal 2
rtsp://admin:senha@192.168.1.13:554/cam/realmonitor?channel=1&subtype=0
```

- Separadores aceitos: espaço, tab, vírgula, ponto e vírgula, `=` ou ` - `.
- Porta depois de `:` é a porta HTTP. Nas URLs `rtsp://`, é a porta RTSP.
- Para NVR, use `canal N` (ou `chN`).
- Se o `.txt` trouxer a senha numa URL, ela vai para o Keychain. Mesmo assim, prefira deixar a senha **fora** do arquivo e informá-la no app, na tela de importação. Lá dá para aplicar a mesma senha a todas as câmeras de uma vez.
- O `.gitignore` bloqueia `cameras.txt`, para a sua lista real nunca ir para o Git.

## Acesso fora de casa

Veja [`docs/acesso-remoto.md`](docs/acesso-remoto.md). Resumo: use **Tailscale** (VPN), e o app funciona igual, sem expor as câmeras na internet.

## Ajustes recomendados na câmera

No painel web da câmera, em **Configuração → Câmera → Vídeo**:

- **Subfluxo:** codificação **MJPEG**, 640×360 ou 704×480, de 5 a 10 fps. É o que alimenta a grade.
- **Fluxo principal:** H.264/H.265, a resolução máxima. É o que o VLC usa.

## Estrutura

```
Sources/AmcrestCore/     lógica pura e testada: modelo, leitura do .txt, URLs da API, extração MJPEG
Sources/AmcrestViewer/   app SwiftUI: telas, rede (autenticação Digest), Keychain
Tests/AmcrestCoreTests/  testes (swift test)
```

## Próximos passos (v0.2)

- RTSP/H.264 dentro do app, com VLCKit ou FFmpeg, em vez de abrir no VLC.
- Eventos de movimento (`eventManager.cgi`) com notificação no macOS.
- Busca e reprodução de gravações do cartão SD ou do NVR (`mediaFileFind.cgi`).
