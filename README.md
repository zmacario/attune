# BitPerfect DX

App de barra de menu para macOS. Quando o **Music** começa a tocar, ele manda o áudio
para o seu **Topping DX3 Pro+** e coloca o DAC na **taxa de amostragem nativa da faixa**,
para o macOS não reamostrar nada no caminho.

Sem isso o DAC fica parado numa taxa só — normalmente a última que alguém usou — e todo
o resto passa pelo conversor de taxa do CoreAudio antes de chegar nele.

## Como usar

```bash
./build.sh && open "build/BitPerfect DX.app"
```

Aparece um ícone de onda na barra de menu com a taxa atual ao lado (`44.1k`, `96k`…).

Para instalar de vez, em `/Applications`, e marcar **Launch at login** no menu:

```bash
./build.sh --install
```

Ele recusa se o app estiver rodando — feche pelo menu antes, senão você recompila e continua
usando a cópia antiga.

## Permissões

Na primeira execução o macOS pede duas coisas. As duas são necessárias:

| Permissão | Para quê | Se você negar |
|---|---|---|
| **Automação → Music** | Perguntar ao Music qual faixa está tocando, e pausar/retomar na troca de taxa | O app não sabe o que está tocando; aparece um aviso laranja no menu |
| **Mídia e Apple Music** | Ler o `.movpkg` da faixa para descobrir a taxa real | Cai para o fallback e passa a chutar a taxa |

A segunda é fácil de perder porque o app a pede numa thread de fundo logo ao iniciar — se
o app parecer parado sem fazer nada, é quase certo que há um diálogo esperando resposta.
Ambas ficam em **Ajustes do Sistema → Privacidade e Segurança**.

**Abra o app pelo Finder**, não por um terminal ou script. O macOS atribui as permissões ao
processo que lançou o app, então lançar por outro programa registra a decisão no nome dele
e bagunça o diálogo.

### Por que recompilar pede a permissão de novo

A assinatura ad-hoc (`codesign --sign -`) gera um *designated requirement* assim:

```
designated => cdhash H"edc7fe90…"
```

Esse hash é o do próprio binário. Mude uma linha de código e ele muda, então cada rebuild
é um app novo aos olhos do macOS e a permissão de **Mídia e Apple Music** é pedida outra
vez. A de **Automação** escapa, porque o TCC guarda pares cliente→alvo por bundle
identifier, não por hash.

Para parar com isso, assine com um certificado autoassinado — aí o requirement se ancora
no certificado, que não muda:

```bash
./tools/create-signing-identity.sh
```

O `build.sh` encontra o certificado sozinho e passa a usá-lo. Se o script falhar no passo
de confiança, dá para fazer pela interface: **Acesso às Chaves → Assistente de Certificado
→ Criar um certificado**, nome `BitPerfect DX Local`, tipo *Assinatura de código*,
autoassinado. O nome precisa bater.

Você também pode apontar outro certificado com `CODESIGN_IDENTITY="nome" ./build.sh`.

## O que ele faz a cada faixa

1. Se o output do sistema não for o DAC, troca.
2. Descobre a taxa nativa da faixa (detalhes abaixo).
3. Ajusta o DAC para essa taxa e sobe o formato do barramento para a maior profundidade
   disponível — o DX3 oferece 24 e 32 bits, e 32 nunca piora nada: só preenche os bits
   menos significativos com zero.
4. Avisa se o volume interno do Music ou o equalizador estiverem estragando o resultado.

Com *Restart track on rate change* ligado (padrão), ele pausa, troca a taxa e recomeça a
faixa do zero. Sem isso, a troca acontece no meio do stream e dá um clique audível.

## Como ele descobre a taxa

Em ordem de preferência:

| Origem | Precisão | Quando |
|---|---|---|
| `.movpkg` | exata | Faixas do Apple Music **baixadas** |
| Arquivo de áudio | exata | AIFF, WAV, ALAC, MP3… na sua biblioteca |
| Metadado do Music | aproximada | Quando existe um `sample rate` no catálogo |
| Fallback configurável | chute | Streaming puro, sem download |

O caso interessante é o `.movpkg`. Um download do Apple Music não é um arquivo de áudio: é
um pacote HLS com **várias variantes da mesma faixa**, cada uma com sua taxa — AAC estéreo,
ALAC lossless e, às vezes, Dolby Atmos. Uma mesma faixa pode ter AAC a 44,1 kHz e Atmos a
48 kHz dentro do mesmo pacote.

O app abre o segmento de inicialização MP4 de cada variante e lê a taxa real do campo
`timescale` da caixa `mdhd`, o codec da caixa `frma` e a profundidade de bits do cookie
ALAC. Depois escolhe qual variante o Music vai tocar:

- variantes **Atmos** (`ec-3`) são ignoradas, porque com Dolby Atmos em *Automático* — o
  padrão — um DAC USB estéreo recebe o stream estéreo, não o espacial. Se você deixou Atmos
  em *Sempre Ativado*, marque **Dolby Atmos is set to Always On** no menu;
- entre as estéreo, ele escolhe **ALAC** se o Lossless estiver ligado no Music
  (lê `losslessEnabled`), senão a AAC de maior bitrate.

Para ver o que tem dentro de uma faixa:

```bash
"build/BitPerfect DX.app/Contents/MacOS/BitPerfectDX" --inspect ~/Music/Music/Media.localized/...
```

## Ajustes que você precisa fazer à mão

O AppleScript do Music não expõe estes, mas todos quebram o bit-perfect:

Em **Music → Ajustes → Reprodução**:

- Sound Enhancer: **desligado**
- Sound Check: **desligado**
- Crossfade Songs: **desligado**
- Qualidade de áudio → **Lossless** ou **Hi-Res Lossless**

O item *Check bit-perfect setup…* do menu roda a checagem e mostra tudo que dá para verificar.

## O que este app não é

- **Não é modo exclusivo.** O Music toca pelo mixer do macOS, e nenhum app externo muda
  isso. Com a taxa igual à da fonte, volume em 100% e nenhum DSP, o caminho é
  bit-transparente — que é o mesmo resultado que o BitPerfect original entregava. Mas se
  outro app tocar junto, o mixer soma os dois. Para modo exclusivo de verdade (hog mode,
  integer mode, DSD nativo) é preciso um player próprio, tipo Audirvana.
- **Streaming sem download continua sendo chute.** Se a faixa não está baixada, não há
  `.movpkg` para ler e o Music não publica a taxa do stream para outros apps. Aí vale o
  fallback configurável (44,1 kHz por padrão). Baixe as faixas que te importam e a leitura
  vira exata.
- **Sem DSD.** O DX3 aceita DSD por USB, mas o Music nunca envia DSD.

## Volume

Deixe o volume interno do Music em 100% — ele atenua em software, antes do áudio sair do
app. O controle de volume do macOS, nesse DAC, vai para o atenuador do próprio DX3, então
esse pode usar à vontade.

## Idiomas

A interface segue o idioma do sistema. Hoje há inglês e português (`Resources/en.lproj`,
`Resources/pt-BR.lproj`); o macOS escolhe sozinho e cai no inglês se não houver
correspondência.

Só a interface é traduzida. As mensagens de log seguem em inglês de propósito — elas
existem para diagnóstico, e um log traduzido é mais difícil de pesquisar e de colar num
relato de problema.

Para ver o app noutro idioma sem mexer no sistema inteiro:

```bash
defaults write com.macario.bitperfectdx AppleLanguages -array pt-BR
```

Feche e reabra o app. Para voltar ao idioma do sistema:

```bash
defaults delete com.macario.bitperfectdx AppleLanguages
```

O mesmo existe na interface, em **Ajustes do Sistema → Geral → Idioma e Região →
Aplicativos**.

### Acrescentar um idioma

Copie `Resources/en.lproj` para `Resources/<código>.lproj`, traduza os dois arquivos
`.strings`, e acrescente o código em `CFBundleLocalizations` no `Info.plist`. O
`build.sh` roda `tools/check-localization.py`, que falha se alguma chave usada no código
faltar em algum idioma — sem isso, uma tradução esquecida apareceria no menu como a
própria chave (`menu.quit`), sem erro nenhum.

## Diagnóstico

O menu tem *Show recent activity…*, que mostra as últimas decisões do app. Pela linha de
comando:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.macario.bitperfectdx"'
```

Passos que demoram mais de 50 ms se registram sozinhos, então lentidão aparece no log sem
precisar mexer em nada. Use `/usr/bin/log` com caminho completo se você tiver uma função
`log` no shell.

```bash
"build/BitPerfect DX.app/Contents/MacOS/BitPerfectDX" --list-devices
```

Mostra taxa atual, formato do barramento e tudo que cada saída aceita. Dá para deixar o
**Audio MIDI Setup** aberto ao lado e ver a taxa mudando sozinha a cada faixa.

## Estrutura

| Arquivo | O que faz |
|---|---|
| `Sources/AudioDevice.swift` | Wrapper sobre a HAL do CoreAudio: enumerar saídas, ler/gravar taxa e formato físico |
| `Sources/MusicBridge.swift` | Apple Events para o Music: faixa atual, caminho, volume, EQ |
| `Sources/Movpkg.swift` | Parser de MP4/HLS que lê a taxa real dos downloads do Apple Music |
| `Sources/TrackFormat.swift` | Junta as origens e decide a taxa da faixa |
| `Sources/Engine.swift` | Escuta `com.apple.Music.playerInfo` e aplica as mudanças |
| `Sources/AppDelegate.swift` | Menu da barra |
| `Sources/Log.swift` | os_log + buffer circular para o *Show recent activity* |
| `Resources/Snapshot.applescript` | A consulta ao Music, em arquivo próprio para o build validar |

Duas coisas que valem saber sobre o build:

- `build.sh` roda `osacompile` no AppleScript antes de empacotar. Vale a pena: nomes curtos
  de variável colidem com a terminologia do Music (`st`, por exemplo, não compila dentro de
  um bloco `tell`), e sem essa checagem o erro só aparece em runtime, silenciosamente.
- Cada rebuild gera uma assinatura ad-hoc nova, e o macOS pede a permissão de Automation de
  novo. Normal — só acontece quando você mexe no código.
