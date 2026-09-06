# Attune

App de barra de menu para macOS. Quando o **Music** começa a tocar, ele manda o áudio para
o seu DAC e coloca o DAC na **taxa de amostragem nativa da faixa**, para o macOS não
reamostrar nada no caminho.

Sem isso o DAC fica parado numa taxa só — normalmente a última que alguém usou — e todo
o resto passa pelo conversor de taxa do CoreAudio antes de chegar nele.

Funciona com qualquer DAC com fio. Foi escrito contra um Topping DX3 Pro+, que aparece
como exemplo aqui e ali, mas nada no código conhece esse aparelho.

## Como usar

```bash
./build.sh && open "build/Attune.app"
```

Aparece um ícone de onda na barra de menu com a taxa atual ao lado (`44.1k`, `96k`…).
Ele fica **laranja** quando algo está atrapalhando o bit-perfect, para você não precisar
abrir o menu só para conferir.

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

O `build.sh` encontra o certificado pelo nome `Attune Local` e passa a usá-lo
sozinho; sem ele, avisa no terminal que assinou ad-hoc. Você também pode apontar outro com
`CODESIGN_IDENTITY="nome" ./build.sh`.

O requirement passa a ser:

```
designated => identifier "com.macario.attune"
              and certificate leaf = H"b87be2ba…"
```

Sem cdhash. Verificado na prática: recompilar com o binário mudado (cdhash diferente) e
relançar não gerou **nenhum** prompt novo de `kTCCServiceMediaLibrary`, contra 7 nos
rebuilds anteriores com assinatura ad-hoc.

**Se o script falhar no `security import`** com "MAC verification failed": o `openssl` do
macOS é LibreSSL, e ele e o `security` discordam de como uma senha vazia é codificada no
MAC do arquivo PKCS#12. Por isso o script gera uma senha aleatória descartável em vez de
usar senha vazia — ela só carrega a chave privada do openssl até o chaveiro e some com o
diretório temporário.

**Se falhar no `add-trusted-cert`**, que altera as configurações de confiança e pede sua
aprovação, dá para fazer pela interface: **Acesso às Chaves → Assistente de Certificado →
Criar um certificado**, nome `Attune Local`, tipo *Assinatura de código*,
autoassinado. O nome precisa bater exatamente.

## O que ele faz a cada faixa

1. Se o output do sistema não for o DAC, troca.
2. Descobre a taxa nativa da faixa (detalhes abaixo).
3. Ajusta o DAC para essa taxa e sobe o formato do barramento para a maior profundidade
   que o aparelho oferecer. Subir a profundidade nunca piora nada: os bits a mais entram
   zerados nas posições menos significativas.
4. Avisa se o volume interno do Music ou o equalizador estiverem estragando o resultado.

Com *Pausar durante a troca de taxa* ligado (padrão), ele pausa, reconfigura e retoma de
onde parou. Vale medido: sem a pausa, o Music continua correndo enquanto o DAC relaqueia, e
a posição do player avança exatamente o tempo de relógio — **~0,74 s da música são pulados**
a cada troca. A pausa custa ~0,12 s a mais de silêncio e não perde nada. As duas soam
parecidas justamente porque têm quase a mesma duração; só uma delas mantém a música
inteira.

### Ajustar a taxa da próxima faixa antes

Ligado por padrão. Resolve um incômodo específico: a troca de taxa cai **no primeiro
segundo da faixa nova**.

A causa é que ninguém pode agir antes. A notificação do Music chega quando a faixa nova já
começou a tocar; daí em diante são ~0,39 s de Apple Event da pausa e **730 ms de relock do
DAC** — custo fixo, medido em 30 trocas da mesma sessão entre 724 e 740 ms, igual em
qualquer direção (44,1↔48, 44,1↔96, 48↔96). Não há ajuste que encurte isso.

Mas o cache sabe o formato de uma faixa sem tocá-la, e o Music diz qual é a próxima da fila
e quanto falta para a atual acabar. Com isso o app pode trocar a taxa **antes do fim da
faixa atual**: quando a próxima começa, o DAC já está certo e ele registra
`already at 96 kHz, nothing to do` — a faixa nova entra limpa desde a primeira nota.

Ele não elimina o silêncio, **muda ele de lugar**: sai do começo da faixa nova e vai para perto do fim
da anterior, onde interrompe algo que já foi ouvido. Nada de áudio se perde, porque a pausa
preserva tudo. Em troca, os últimos ~2,5 s da faixa que termina tocam reamostrados, já na
taxa da próxima. A margem de 2,5 s não é arbitrária: o Apple Event da pausa já levou de 77 a
439 ms, e uma troca que escorregasse para depois da virada cairia exatamente no lugar que
este recurso existe para evitar.

Ele só age quando **tudo** é conhecido, e não faz nada quando falta qualquer peça:

| condição | por quê |
|---|---|
| *Pausar durante a troca de taxa* ligado | é a pausa que faz isso não custar áudio |
| modo aleatório desligado | com shuffle, a próxima por índice não é a que toca |
| a próxima faixa é identificável | rádio e outras fontes não têm playlist |
| o formato dela já está no cache | faixa nunca ouvida não tem o que antecipar |
| sobra mais que 2,5 s | tarde demais para preparar |

Se a faixa mudar antes da hora marcada — você pulou, ou o Music adiantou — a antecipação se
recolhe sem fazer nada (`pre-switch: track already changed, standing down`).

Duas armadilhas custaram uma versão cada, e as duas estão no código como comentário:

**A antecipação se desfazia sozinha.** O `play()` dela faz o Music emitir uma notificação, e
a faixa que essa notificação nomeia ainda é a que está terminando. O app olhava, via o DAC
na taxa "errada" e corrigia de volta — três trocas em vez de uma, pior que sem o recurso.
Agora ele segura a configuração preparada até a faixa realmente virar
(`holding the rate prepared for the next track`).

**O temporizador não disparava.** Este é um app de barra de menu sem janelas, e o
adiamento que o macOS aplica a apps nesse estado engoliu um `asyncAfter` inteiro: ele não
rodou na hora marcada e acabou executando dentro da pausa que o caminho comum já tinha
começado. Agora é um `DispatchSource` estrito com folga de 50 ms, mais um `beginActivity`
enquanto há antecipação pendente. Medido depois: disparos com 9 e 33 ms de atraso.

Medido na dupla que originou tudo, *Mystical Magical* (44,1) → *In The Light Of Day* (96):

| | antes | com o recurso |
|---|---|---|
| trocas de taxa | 1, no começo da faixa nova | 1, no fim da anterior |
| silêncio | 0,85 s na primeira nota | 0,89 s, 2,4 s antes da virada |
| início da faixa nova | interrompido | intacto |

## O menu

```
DX3 Pro+ · 96 kHz                                    ← dispositivo e taxa atual
Wire: 96 kHz 32-bit int (packed) 2ch                 ← o que sai no barramento
▶ Seven Nation Army — The White Stripes · 24-bit / 192 kHz (download)
─────────────────────────────────────────
☑ Route Music to this device
☑ Match the track's sample rate                      ← clicar não fecha o menu
☑ Use the deepest bit format
☑ Pause during rate changes
☑ Set the next track's rate in advance
☐ Restore previous output when Music stops
─────────────────────────────────────────
Output device                                     ▸   ← DACs num grupo, atualizado ao vivo
When the rate is unknown                          ▸
─────────────────────────────────────────
Re-apply now
⚠️ Check bit-perfect setup…                          ← o ⚠️ só aparece quando há algo a corrigir
Show recent activity…
Open Audio MIDI Setup
─────────────────────────────────────────
☑ Launch at login
Quit
```

Três detalhes de comportamento que não são óbvios olhando:

**Os interruptores não fecham o menu.** Um `NSMenu` fecha assim que um item é selecionado
e não há como desligar isso, então os seis viraram views próprias que absorvem o clique —
o menu nunca chega a ver uma seleção. Dá para configurar tudo de uma vez. As ações de
verdade (*Re-apply now*, *Check bit-perfect setup…*, *Quit*) continuam fechando, como
esperado.

**A lista de dispositivos acompanha o hardware.** Conectar ou desconectar um DAC muda o
submenu na hora, mesmo com o menu já aberto — ele é reconstruído pelo mesmo aviso do
CoreAudio que dispara o reencaminhamento. O menu principal continua nunca sendo reconstruído
enquanto aberto, porque isso arrancaria a linha sob o cursor; submenu tem ciclo próprio.

**O cabeçalho tem sempre três linhas, e se atualiza com o menu aberto.** A contagem fixa é
o que permite atualizar no lugar: qualquer linha que aparecesse ou sumisse empurraria as
outras para cima ou para baixo, e um interruptor sairia de debaixo do seu cursor no meio
do clique. Deixe o menu aberto durante uma troca de faixa e veja as três linhas mudarem
sem nada se mexer.

**O aviso mora no item que o resolve.** Volume interno do Music fora de 100% ou
equalizador ligado marcam o *Check bit-perfect setup…* com ⚠️ e tingem o ícone da barra de
laranja. O detalhe fica no relatório, a um clique — mais informativo que uma linha de
resumo, e o cabeçalho continua sendo só fato.

Volume e EQ do Music mudam sem notificar ninguém — veja **Verificação periódica** abaixo.

## Qual DAC ele usa

Três regras, nesta ordem:

1. **O dispositivo escolhido por último no menu do app**, se estiver conectado.
2. Senão, **o DAC conectado mais recentemente**.
3. Senão, **os alto-falantes internos**.

O dispositivo salvo é uma preferência que desempata, não um alvo que o app fica esperando:
desconecte-o e outro DAC assume sozinho. É por isso que o visto no submenu marca o
dispositivo **em uso**, e não o salvo — os dois divergem justamente quando o preferido está
fora e outro assumiu.

### O que conta como DAC

USB, Thunderbolt e FireWire. Bluetooth e AirPlay ficam de fora porque reamostram por conta
própria e não têm como ser bit-perfect. DisplayPort e HDMI também ficam fora da adoção
automática — são com fio e carregam áudio digital, mas são um monitor ou uma TV, não algo
para o app adotar sozinho. Continuam escolhíveis à mão, e uma escolha manual vale para
qualquer saída.

### Ordem de conexão

O CoreAudio não informa há quanto tempo um aparelho está plugado, então o app mantém o
próprio registro: um UID que aparece onde não estava é carimbado com a hora, e um que some
é esquecido — desplugar e replugar conta como novo. Fica gravado nas preferências, para a
ordem sobreviver a um relançamento com tudo ainda conectado. Aparelhos que já estavam lá
na primeira execução empatam e são desempatados por nome, para não trocarem de lugar entre
uma execução e outra.

### Conectar e desconectar

O app escuta `kAudioHardwarePropertyDevices` e reencaminha em 0,3 s — a pausa é para o HAL
assentar antes de perguntar o que restou. Vale para os dois lados: desconectar o DAC que
está tocando manda o áudio para o próximo em vez de deixá-lo nos alto-falantes, e conectar
um DAC novo o coloca em jogo na hora.

Isso **não** é o mesmo que a verificação periódica abaixo. Aquela atualiza o que o menu
mostra; ela nunca reencaminha nada. Tratar as duas como um problema só foi o que deixou o
hot-plug sem resposta por um tempo.

## Verificação periódica

O app reage a `com.apple.Music.playerInfo`, que o Music publica ao trocar de faixa, pausar
e retomar. Mas **volume interno e equalizador não publicam nada** — mudar qualquer um dos
dois é invisível para qualquer app de fora. Sem verificar de tempos em tempos, o aviso só
apareceria na coincidência de o ajuste já estar errado no instante em que uma faixa
começasse, que é justamente quando você não precisa dele.

Então há um timer relendo essas duas coisas:

| | |
|---|---|
| Intervalo | 15 segundos |
| Folga | 5 segundos, para o macOS agrupar o despertar com outros que já faria |
| Com o Music fechado | não manda Apple Event nenhum; a checagem de processo é local |
| Custo medido | 0,0% de CPU, e nada acrescentado ao log |

Duas decisões evitam que isso vire desperdício. O `EngineStatus` é comparável e o
`publish()` descarta atualizações idênticas — senão o menu seria reescrito a cada 15
segundos sem nada ter mudado. E as duas imagens da barra são construídas uma vez, não a
cada avaliação.

Para mexer no intervalo, `pollInterval` e `pollLeeway` estão em
[Engine.swift:31](Sources/Engine.swift#L31).

## Abrir ao iniciar sessão

O item **Launch at login** no menu registra o app via `SMAppService` (macOS 13+). O que
torna isso menos trivial do que parece é que `SMAppService` tem **quatro** estados, e não
dois:

| Estado | O que o menu mostra |
|---|---|
| `.enabled` | "Launch at login", marcado |
| `.requiresApproval` | "Launch at login (approve in System Settings…)" — clicar abre o painel |
| `.notRegistered` | normal; clicar registra |
| `.notFound` | desabilitado, com a dica de mover o app para `/Applications` |

O caso que engana é o `.requiresApproval`: o macOS aceita o registro mas exige que você
confirme em **Ajustes do Sistema → Geral → Itens de Início**. Tratar isso como
"desligado" — que era o comportamento original — produzia uma caixa desmarcada que, ao
ser clicada, chamava `register()` de novo e não mudava nada visível. Nesse estado o
clique agora abre o painel em vez de repetir um registro que já deu certo.

Se você registrar o app pelos Ajustes do Sistema em vez de pelo menu, o menu enxerga e
mostra marcado — é o mesmo registro.

Uma armadilha para quem for mexer no código: **`SMAppService.status` bloqueia
indefinidamente** quando lido fora de um app propriamente lançado, e foi visto travando
assim durante o desenvolvimento. Por isso ele é lido em segundo plano e o menu desenha um
valor em cache, em vez de consultá-lo enquanto monta os itens.

## Como ele descobre a taxa

Em ordem de preferência:

| Origem | Precisão | Quando |
|---|---|---|
| Lembrado | exata | Faixa já ouvida antes — aplicada antes de perguntar nada |
| Log do player | exata | **Todas** as faixas — veja abaixo |
| `.movpkg` | exata | Faixas do Apple Music **baixadas** |
| Arquivo de áudio | exata | AIFF, WAV, ALAC, MP3… na sua biblioteca |
| Metadado do Music | aproximada | Quando existe um `sample rate` no catálogo |
| Fallback configurável | chute | Streaming quando o log não responde |

O caso interessante é o `.movpkg`. Um download do Apple Music não é um arquivo de áudio: é
um pacote HLS com **várias variantes da mesma faixa**, cada uma com sua taxa — AAC estéreo,
ALAC lossless e, às vezes, Dolby Atmos. Uma mesma faixa pode ter AAC a 44,1 kHz e Atmos a
48 kHz dentro do mesmo pacote.

O app abre o segmento de inicialização MP4 de cada variante e lê a taxa real do campo
`timescale` da caixa `mdhd`, o codec da caixa `frma` e a profundidade de bits do cookie
ALAC. Depois escolhe qual variante o Music vai tocar:

- variantes **Atmos** (`ec-3`) são ignoradas de vez. Ler o pacote mostra que existe uma
  variante Atmos, mas não se o Music a escolheu — e isso já era um ajuste manual no menu,
  que pedia a você uma configuração interna do Music e errava em silêncio quando respondido
  errado. O log do player diz qual variante foi decodificada, então o palpite foi apagado
  junto com o interruptor;
- entre as estéreo, ele escolhe **ALAC** se o Lossless estiver ligado no Music
  (lê `losslessEnabled`), senão a AAC de maior bitrate.

Para ver o que tem dentro de uma faixa:

```bash
"build/Attune.app/Contents/MacOS/Attune" --inspect ~/Music/Music/Media.localized/...
```

### Lembrando o que já foi ouvido

Onde o tempo vai, medido: resolver custa **3 ms**; os outros ~330 são o *debounce* de um
quarto de segundo e o Apple Event que pergunta ao Music qual faixa está tocando. Um cache
consultado depois disso não economizaria nada.

Mas a notificação do Music **já traz o nome da faixa**. Então uma faixa ouvida antes é
aplicada direto dela, sem perguntar nada — medido em **1 ms** depois da notificação, contra
~330. É essa a diferença entre a pausa começar dentro da música ou na borda dela.

Só formatos que o próprio player reportou são guardados. Guardar um chute faria com que ele
fosse aplicado instantaneamente em toda execução seguinte, o que é pior que chutar uma vez.
O caminho normal continua rodando e continua tendo a última palavra: se o player discordar,
corrige dentro da janela de acomodação.

É isso que mantém o cache honesto quando a Apple troca o formato de uma faixa: na primeira
audição depois da troca o valor velho é aplicado na hora e o player corrige ~1,5 s depois —
duas transições nessa audição, uma só nas seguintes, porque a entrada é regravada. Reouvir
uma faixa cujo formato não mudou não escreve nada.

O dicionário fica **em memória**, carregado uma vez na partida, fora do main thread.
Converter o dicionário guardado no plist percorre todas as entradas — 2 ms com 4 mil, 53 ms
com 50 mil — e a busca acontece no main thread, na notificação do Music; reler a cada faixa
gastaria justamente o milissegundo que o cache existe para ganhar. Carregado uma vez, a
busca é plana em qualquer tamanho. O teto de 50 mil entradas está lá para o plist não
crescer sem limite, não para expirar nada: ao ser ultrapassado o cache é zerado inteiro, e
uma biblioteca desse tamanho não é uma biblioteca real.

Um efeito colateral de estar em memória: apagar o cache por fora
(`defaults delete com.macario.attune formatCache`) só tem efeito com o app **fechado** — de
app aberto, ele regrava o que tem na memória.

### Lendo o log do player

Uma faixa em streaming não tem arquivo para inspecionar, e o Music reporta a taxa dela como
zero. Sem isso o app chutaria 44,1 kHz para todas — rebaixando pela metade um stream de
96 kHz, em silêncio.

O log é consultado para **todas** as faixas, não só as em streaming. Ele é a única fonte que
sabe qual variante o Music realmente escolheu, incluindo Dolby Atmos — ler o `.movpkg` vê
que uma variante Atmos existe, não que ela está tocando. Um download continua resolvendo do
arquivo na hora quando o log ainda não respondeu, então nada passou a esperar; se depois as
duas leituras discordarem, a correção acontece dentro da janela de acomodação.

O player do CoreMedia registra no log do sistema a variante que **realmente decodificou**:

```
<0x7fa79005f600|I/QX.257>: [AudioFormat qlac is decodable] [AudioChannels 2]
[Rendition Lossless] [SampleRate 96000] [BitDepth 24]
```

Quatro decisões aí não são óbvias, e cada uma custou um diagnóstico errado antes de ser
entendida.

**Um `log stream` de vida longa, não consultas por faixa.** Cada `log show` gasta ~800 ms
só para lançar o processo, e era esse custo — não espera por informação — que fazia a taxa
se acomodar quase um segundo depois do início da faixa. Com o stream a leitura vira acesso
à memória e a resolução cai para ~0,3 s, o que põe a pausa perto do limite entre as músicas.
Custa 0,3% de CPU e 5 MB.

**Nem `OSLogStore`, que seria mais barato.** Ele lê o arquivo persistido, e entradas de
nível info levam **minutos** para chegar lá: uma linha recém-escrita pelo próprio processo
seguia invisível a ele depois de 30 segundos, enquanto a ferramenta a via na hora. Uma
resposta barata sobre um estado de minutos atrás não vale nada.

**A atribuição é por identidade, não por tempo.** A mensagem não nomeia a faixa, e decidir
pelo horário fazia faixas vizinhas trocarem de formato quando se pulava rápido. Mas cada
faixa tem seu próprio token (`I/QX.257` acima), compartilhado pelos relatórios repetidos
dela — estava impresso em toda linha, e eu o tratava como ruído hexadecimal.

**Correção só nos 3 primeiros segundos.** Pular mais rápido do que o player reporta deixa o
app descrevendo uma faixa enquanto o player descreve outra, e nenhuma regra reconcilia duas
fontes amostradas em momentos diferentes. Um relatório novo faz o app reavaliar, mas só
dentro dessa janela: depois dela, uma correção seria um corte no meio da música.

Downloads não passam por aqui — o `.movpkg` é autoritativo e resolve na hora.

Se o log não responder, o app desliga a leitura, registra o motivo e volta ao comportamento
anterior. A verificação é feita uma vez, com uma pergunta que precisa ter resposta **e** ser
sobre algo recente: perguntar se "qualquer entrada" pode ser lida responde sim com as
entradas do próprio app.

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
- **O streaming depende de um log interno da Apple.** Funciona, e foi verificado em 44,1,
  48 e 96 kHz, mas a mensagem que o app lê não é API pública. Se ela mudar de forma numa
  atualização do macOS, o streaming volta ao fallback — sem quebrar mais nada.
- **Sem DSD.** Muitos DACs aceitam DSD por USB, mas o Music nunca envia DSD.

## Consumo

Medido num MacBook Pro Intel, com o app ligado e o Music tocando o tempo todo:

| | |
|---|---|
| memória | **16,7 MB** (pico 17,1 MB) |
| CPU em repouso | **0,07–0,08%** |
| CPU desde a partida | 0,50% |
| threads | 5 a 9 |

O consumo em repouso vem de duas medições independentes que chegaram ao mesmo lugar: uma
janela cronometrada de 100 s (0,080%) e a diferença dos contadores acumulados ao longo de
157 s (0,070%). Os 0,50% desde a partida são maiores porque incluem a inicialização, a
sondagem do log do player e várias trocas de faixa em treze minutos — não é o número do dia
a dia.

O app dorme entre eventos. Ele acorda com a notificação do Music (uma por faixa), na
verificação de 15 s — com folga generosa, justamente para o sistema agrupá-la com outros
despertares — e quando um dispositivo entra ou sai.

A memória é o *physical footprint*, que é como a Apple contabiliza um processo; o `ps`
mostra ~35 MB de RSS, mas isso conta páginas compartilhadas de frameworks do sistema que
existiriam de qualquer forma. O cache de formatos tem peso desprezível nisso: 47 faixas
ocupam ~4 KB, e mesmo cheio, com 50 000, seriam ~4 MB.

A contagem de threads varia porque quase todas são threads de trabalho que o libdispatch
cria e recolhe sozinho — o app declara só duas filas próprias (`attune.engine` e
`attune.music`) mais a principal, e o tempo de CPU fica quase todo nesta última.

## Volume

Deixe o volume interno do Music em 100% — ele atenua em software, antes do áudio sair do
app. Já o controle de volume do macOS, quando o DAC expõe um, é repassado ao atenuador do
próprio aparelho — esse pode usar à vontade. O item *Check bit-perfect setup…* diz qual dos
dois casos é o seu.

## Idiomas

A interface segue o idioma do sistema. Hoje há inglês e português (`Resources/en.lproj`,
`Resources/pt-BR.lproj`); o macOS escolhe sozinho e cai no inglês se não houver
correspondência.

Só a interface é traduzida. As mensagens de log seguem em inglês de propósito — elas
existem para diagnóstico, e um log traduzido é mais difícil de pesquisar e de colar num
relato de problema.

Para ver o app noutro idioma sem mexer no sistema inteiro:

```bash
defaults write com.macario.attune AppleLanguages -array pt-BR
```

Feche e reabra o app. Para voltar ao idioma do sistema:

```bash
defaults delete com.macario.attune AppleLanguages
```

O mesmo existe na interface, em **Ajustes do Sistema → Geral → Idioma e Região →
Aplicativos**.

### Acrescentar um idioma

Copie `Resources/en.lproj` para `Resources/<código>.lproj`, traduza os dois arquivos
`.strings`, e acrescente o código em `CFBundleLocalizations` no `Info.plist`. O
`build.sh` roda `tools/check-localization.py`, que falha se alguma chave usada no código
faltar em algum idioma — sem isso, uma tradução esquecida apareceria no menu como a
própria chave (`menu.quit`), sem erro nenhum.

## O ícone

Desenhado por código, em [tools/make-icon.swift](tools/make-icon.swift), e empacotado com
`iconutil`. Não há catálogo de assets porque o `/usr/bin/actool` é um stub que precisa do
Xcode completo — o `iconutil`, que faz o mesmo para ícones, vem com as Command Line Tools.

Para mudar o desenho, edite o Swift e recompile: o `build.sh` regenera o `.icns` sozinho
quando o fonte está mais novo que ele. A regeneração é condicional porque compila um
segundo binário, e o ícone muda muito menos que o app.

```bash
./tools/make-icon.sh    # se quiser regenerar sem recompilar o app
```

O glifo é o mesmo símbolo SF que a barra de menu usa, de propósito: o ícone do Dock e o da
barra passam a se reconhecer como o mesmo app.

**O ícone da barra tem duas versões**, e a diferença entre elas não é óbvia. A normal é uma
*template image*, que o macOS pinta sozinho para acompanhar o modo claro ou escuro. A de
aviso **não** é template, com o laranja embutido na imagem — porque a barra de menu desenha
template images em monocromático e ignora `contentTintColor`. Tentar tingir a versão normal
não produz efeito nenhum.

## Diagnóstico

Para entender qual dispositivo o app escolheu e por quê:

```bash
"build/Attune.app/Contents/MacOS/Attune" --resolve
```

```
DACs by recency:
    DX3 Pro+  (USB)  connected 16:54:56
    HiBy FC4  (USB)  connected 17:02:11
Chosen in app: DX3 Pro+ — connected
Rule applied: 1. the device chosen in the app
Target: DX3 Pro+
```

Ele diz qual das três regras valeu, o que é difícil de deduzir olhando só o resultado.

Para acompanhar o que o player está reportando, ao vivo:

```bash
"build/Attune.app/Contents/MacOS/Attune" --watch-player
```

```
19:54:02  Lossless  44.1 kHz  16-bit  2ch  I/QX.257
20:06:10  Lossless  96 kHz    24-bit  2ch  I/YH.259
```

E, para verificar o ciclo inteiro sem fazer nada à mão:

```bash
tools/test-switching.sh 8 1.2      # 8 pulos, 1,2 s entre eles
```

Ele reinstala, abre o app, pula faixas pelo Music e confere se o DAC terminou na taxa que o
player reportou por último — perguntando ao app **qual dispositivo ele está mirando**, em vez
de presumir um. Presumir foi o terceiro falso negativo que essa ferramenta produziu. A verificação é sobre o **estado final**, não sobre cada leitura
intermediária: pular mais rápido do que o player reporta produz desencontros transitórios
que são esperados, enquanto a taxa em que você fica ouvindo nunca pode estar errada.

Ele responde `INCONCLUSIVE` quando o player ainda está falando durante a medição. Sem isso
ele comparava o DAC contra o formato da faixa que o player já estava preparando, e reprovava
o app quando o app estava certo.


O menu tem *Show recent activity…*, que mostra as últimas decisões do app. Pela linha de
comando:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.macario.attune"'
```

Passos que demoram mais de 50 ms se registram sozinhos, então lentidão aparece no log sem
precisar mexer em nada. Use `/usr/bin/log` com caminho completo se você tiver uma função
`log` no shell.

```bash
"build/Attune.app/Contents/MacOS/Attune" --list-devices
```

Mostra taxa atual, formato do barramento e tudo que cada saída aceita. Dá para deixar o
**Audio MIDI Setup** aberto ao lado e ver a taxa mudando sozinha a cada faixa.

## Estrutura

| Arquivo | O que faz |
|---|---|
| `Sources/AudioDevice.swift` | Wrapper sobre a HAL do CoreAudio: enumerar saídas, ler/gravar taxa e formato físico |
| `Sources/MusicBridge.swift` | Apple Events para o Music: faixa atual, caminho, volume, EQ |
| `Sources/Movpkg.swift` | Parser de MP4/HLS que lê a taxa real dos downloads do Apple Music |
| `Sources/PlayerLog.swift` | Lê do log do sistema o formato que o player decodificou |
| `Sources/TrackFormat.swift` | Junta as origens e decide a taxa da faixa |
| `Sources/Engine.swift` | Escuta `com.apple.Music.playerInfo` e aplica as mudanças |
| `Sources/AppDelegate.swift` | Menu da barra e diálogos |
| `Sources/ToggleMenuItemView.swift` | O item de menu que alterna sem fechar o menu |
| `Sources/Settings.swift` | As opções, guardadas em `UserDefaults` |
| `Sources/Localization.swift` | O `localized()` que lê as tabelas de idioma |
| `Sources/Log.swift` | os_log + buffer circular para o *Show recent activity* |
| `Resources/Snapshot.applescript` | A consulta ao Music, em arquivo próprio para o build validar |
| `Resources/*.lproj` | Textos da interface, um diretório por idioma |
| `tools/make-icon.swift` | Desenha o ícone; `make-icon.sh` empacota com `iconutil` |
| `tools/check-localization.py` | Falha o build se faltar tradução |
| `tools/test-switching.sh` | Ciclo completo de verificação: reinstala, pula faixas, confere o DAC |
| `tools/create-signing-identity.sh` | Cria o certificado que preserva as permissões |

Duas coisas que valem saber sobre o build:

- `build.sh` roda `osacompile` no AppleScript antes de empacotar. Vale a pena: nomes curtos
  de variável colidem com a terminologia do Music (`st`, por exemplo, não compila dentro de
  um bloco `tell`), e sem essa checagem o erro só aparece em runtime, silenciosamente.
- Cada rebuild gera uma assinatura ad-hoc nova, e o macOS pede a permissão de Automation de
  novo. Normal — só acontece quando você mexe no código.
