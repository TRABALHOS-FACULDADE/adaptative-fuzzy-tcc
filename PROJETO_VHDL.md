# Arquitetura de Interação dos Arquivos VHDL

## Mapeamento SOA

| Papel SOA | Arquivo VHDL |
|---|---|
| **Service Registry** | `config_registers.vhd` |
| **Service Broker** | `fuzzy_top.vhd` |
| **Microserviços** | os outros 7 arquivos |

---

## 1. `config_registers.vhd` — o Service Registry

No SOA clássico, o Service Registry é o repositório central onde os serviços publicam suas capacidades e onde os consumidores buscam o que precisam.

```
      Quem ESCREVE:             Quem LÊ:
      ─────────────             ────────
      uart_receiver  ──[porta 1]──►  config_registers  ──► fuzzifier ×2
      adaptation_eng ──[porta 2]──►       (33 regs)    ──► rule_evaluator
                                                        ──► aggregator
                                                        ──► defuzzifier
                                                        ──► adaptation_engine
```

Os 33 registradores são divididos em zonas de responsabilidade:

| Endereços | Zona | Dono da escrita |
|---|---|---|
| `0x00..0x11` | Parâmetros MF das 6 funções de pertinência | UART **ou** ms_adapt |
| `0x12..0x1A` | Classes das 9 regras | UART |
| `0x1B..0x1D` | Valores crisp das classes de saída | UART |
| `0x1E..0x20` | Parâmetros de adaptação (alpha, N, k) | UART |

O `config_registers` **nunca processa nada** — ele só guarda estado e expõe saídas combinacionais. É um repositório passivo, exatamente como um registry.

---

## 2. `fuzzy_top.vhd` — o Service Broker

O Broker é quem conhece todos os serviços, sabe a ordem de execução, e orquestra quem age quando. A FSM de 8 estados é o orquestrador:

```
S_IDLE ──start──► S_FUZZ_START ──► S_FUZZ_WAIT ──done──► S_DEFUZZ_START
                                                                │
S_IDLE ◄──── S_ADAPT_WAIT ◄──── S_ADAPT_START ◄──── S_OUTPUT ◄┘
```

O Broker **não processa nada diretamente** — ele só emite pulsos `start` para os microserviços e aguarda o sinal `done`/`busy`. Todo o dado flui pelos sinais internos (`cfg_*`, `mu_*`, `str_*`, `agg_*`) que o Broker apenas roteia.

> **Observação:** o Broker também define a prioridade de escrita no Registry: a porta 1 (UART) tem precedência sobre a porta 2 (ms_adapt). Se ambas tentam escrever no mesmo ciclo, UART ganha — isso está codificado na ordem dos `elsif` dentro de `config_registers.vhd`.

---

## 3. Os 7 Microserviços

### `uart_receiver.vhd` — ms_config

**Papel:** Canal de entrada para configuração externa. Converte bits seriais em escritas no Registry.

```
pino uart_rx ──► [FSM UART 8N1] ──► rx_byte ──► [FSM Protocolo 3 bytes] ──► write_en + addr + data
```

Dois níveis de FSM independentes:
- **Nível de bit** (`RX_IDLE → RX_START_BIT → RX_DATA_BITS → RX_STOP_BIT`): desserializa a UART, amostrando cada bit no centro do período
- **Nível de byte** (`P_WAIT_ADDR → P_WAIT_HIGH → P_WAIT_LOW`): acumula 3 bytes e gera a escrita no Registry

Este microserviço opera **totalmente independente** do Broker. Ele não recebe `start` de ninguém e pode escrever no Registry a qualquer momento, inclusive enquanto uma inferência está em andamento.

---

### `fuzzifier.vhd` (×2) — ms_fuzzify_input1 / ms_fuzzify_input2

**Papel:** Converter um valor crisp em 3 graus de pertinência (μ_LOW, μ_MED, μ_HIGH).

```
config_registers ──► [a,b,c × 3 MFs] ──┐
                                         ├──► fuzzifier ──► [μ_low, μ_med, μ_high] + done
sensor_data ────────────────────────────┘
```

Cada fuzzifier instancia internamente 3 `triangular_mf` que rodam **em paralelo**. Esta é a vantagem mais clara do FPGA: em Python é um loop `for mf in [low, med, high]`; em hardware as 3 divisões acontecem simultaneamente.

O sinal `done` é gerado quando **todos os 3** triangular_mf sinalizarem conclusão (via registradores internos `done_low_r`, `done_med_r`, `done_high_r`).

Os dois fuzzifiers recebem o mesmo pulso `fuzz_start` do Broker e rodam **em paralelo um com o outro** — o Broker aguarda ambos no estado `S_FUZZ_WAIT` com a condição `fuzz1_done_r AND fuzz2_done_r`.

---

### `triangular_mf.vhd` — bloco interno do ms_fuzzify

Não é um microserviço SOA autônomo — é um **bloco reutilizável** instanciado 6 vezes no total (3 por fuzzifier × 2 fuzzifiers). Ele calcula:

```
μ(x) = 0                    se x ≤ a  ou  x ≥ c
μ(x) = (x - a) / (b - a)   se a < x ≤ b
μ(x) = (c - x) / (c - b)   se b < x < c
μ(x) = 1                    se a == b (ombro esquerdo  e  x ≤ b)
μ(x) = 1                    se b == c (ombro direito   e  x ≥ b)
```

O divisor em ponto fixo Q8.8 dentro dele é o motivo pelo qual o fuzzifier não é puramente combinacional — ele precisa de ciclos de clock para a divisão.

---

### `rule_evaluator.vhd` — ms_rule_eval

**Papel:** Avaliar as 9 regras fuzzy (operação AND = MIN entre μ do input1 e μ do input2).

```
[μ1_low, μ1_med, μ1_high]  ──┐
                               ├──► 9 × MIN ──► [strength_0 .. strength_8]
[μ2_low, μ2_med, μ2_high]  ──┘
```

**Puramente combinacional**, zero ciclos de latência após as entradas estabilizarem. No Broker, não existe estado de espera dedicado a ele — o resultado aparece automaticamente quando os fuzzifiers terminam, e o Broker vai direto de `S_FUZZ_WAIT` para `S_DEFUZZ_START`, já com os `strength_*` prontos.

---

### `aggregator.vhd` — ms_aggregate

**Papel:** Para cada classe de saída (OK, ALERT, CRITICAL), calcular o MAX entre as forças das regras que apontam para ela.

```
[strength_0..8] ──┐
                   ├──► MAX por classe ──► [agg_ok, agg_alert, agg_critical]
[rule_class_0..8] ─┘   (configurável)
```

Também **puramente combinacional**. A "configurabilidade" das regras vem dos `rule_class_*` lidos do Registry — o mapeamento regra→classe não é hard-coded, mas configurado via UART.

---

### `defuzzifier.vhd` — ms_defuzzify

**Papel:** Converter os 3 pesos agregados em um valor crisp final + classificação.

```
[agg_ok, agg_alert, agg_crit] ──┐
                                  ├──► Σ(peso × valor) / Σ(peso) ──► crisp_output + final_class
[val_ok, val_alert, val_crit] ──┘
```

É **sequencial** (precisa de divisão em ponto fixo) e é o único do pipeline principal com `start` e `done` separados explicitamente no controle do Broker (`S_DEFUZZ_START → S_DEFUZZ_WAIT`).

---

### `adaptation_engine.vhd` — ms_adapt

**Papel:** Microserviço de adaptação online. Opera entre ciclos de inferência e atualiza o Registry com novos parâmetros MF.

Este é o mais complexo e o mais novo — sem equivalente no protótipo original do TCC. Ele tem **duas interações fundamentais** com o Registry:

```
config_registers ──► [MF params atuais + alpha, N, k] ──► adaptation_engine
adaptation_engine ──► [novos MF params (18 escritas)] ──► config_registers
                              (via adapt_wr_en/addr/data)
```

O fluxo interno da FSM de 22 estados:

```
IDLE
 │ start
 ▼
WELFORD_1..6       ← Atualiza n, mean, m2 para os 2 inputs
 │
 ▼
CHECK_ADAPT ────── n % N ≠ 0 ────────────────────────────────► DONE
 │ n % N == 0
 ▼
VARIANCE_1..2      ← var = m2 / (n-1)
 │
 ▼
SQRT_1..2          ← std = √var  (Newton-Raphson, 4 iterações)
 │
 ▼
CALC_TARGETS_1..2  ← p1 = mean - k·std,  p2 = mean,  p3 = mean + k·std
 │
 ▼
EMA_1..2           ← p_new = p_current + α·(p_target - p_current)
 │
 ▼
DERIVE_1..2        ← LOW=(min,min,p1)  MED=(2p1-p2, p2, 2p3-p2)  HIGH=(p3,max,max)
 │
 ▼
WRITE_REGS         ← 18 escritas nos config_registers (1 por ciclo de clock)
 │
 ▼
DONE
```

---

## 4. Diagrama completo de interação de sinais

```
                    ┌─────────────────────────────────────────────┐
                    │           fuzzy_top.vhd (BROKER)            │
                    │           FSM: 8 estados                    │
                    └──┬──────────────────────────────────────────┘
                       │  fuzz_start / defuzz_start / adapt_start
                       ▼
         ┌─────────────────────────────────────────────────────┐
    ══►  │         config_registers.vhd (REGISTRY)             │  ◄══ uart_receiver
         │         33 registradores de 16 bits                 │  ◄══ adaptation_engine
         │         leitura combinacional contínua              │      (adapt_wr_en/addr/data)
         └──┬──────────────────┬─────────────────┬────────────┘
            │ MF params ×2     │ rule classes     │ output vals + adapt params
            ▼                  ▼                  ▼
     ┌─────────────┐    ┌───────────────┐   ┌─────────────┐   ┌──────────────────┐
     │ fuzzifier×2 │    │ rule_evaluator│   │  defuzzifier│   │adaptation_engine │
     │  (ms_fuzz)  │    │ (ms_rule_eval)│   │ (ms_defuzz) │   │   (ms_adapt)     │
     └──────┬──────┘    └───────┬───────┘   └──────┬──────┘   └──────────────────┘
            │ μ_low/med/high×2  │ strength_0..8     │ crisp_out + class
            └──────────────────►│                   │
                          ┌─────┴──────┐            │
                          │ aggregator │             │
                          │(ms_aggr)   │             │
                          └─────┬──────┘             │
                                │ agg_ok/alert/crit  │
                                └───────────────────►│
                                                      │ done
                                                      ▼
                                               result_class
                                               result_value
                                               result_valid
```

---

## 5. O loop de adaptação

O que torna o sistema genuinamente adaptativo é um **loop de realimentação implícito** mediado pelo Registry:

```
Ciclo N:    ms_adapt lê MF params do Registry
               ↓ calcula novos params (Welford + EMA + derivação)
               ↓ escreve 18 novos params no Registry

Ciclo N+1:  fuzzifier lê MF params do Registry
               ↓ usa os params atualizados
               ↓ inferência com novo comportamento
```

Este loop não tem coordenação explícita além da sequência da FSM do Broker:

```
S_OUTPUT → S_ADAPT_START → S_ADAPT_WAIT → S_IDLE
```

O Registry é o ponto de encontro — `ms_adapt` escreve, `ms_fuzzify` lê. Eles **nunca se comunicam diretamente**.

---

## 6. Tabela resumo: tipo de cada arquivo

| Arquivo | Papel SOA | Tipo de lógica | `start`/`done` |
|---|---|---|---|
| `fuzzy_top.vhd` | **Service Broker** | FSM de orquestração | — emite pulsos |
| `config_registers.vhd` | **Service Registry** | Registradores + leitura combinacional | — passivo |
| `uart_receiver.vhd` | ms_config | FSM dupla (bit + byte) | autônomo |
| `fuzzifier.vhd` | ms_fuzzify_input1/2 | Sequencial (divisão Q8.8) | `start` + `done` |
| `triangular_mf.vhd` | Bloco interno | Combinacional + divisão | `start` + `done` |
| `rule_evaluator.vhd` | ms_rule_eval | **Combinacional puro** | nenhum |
| `aggregator.vhd` | ms_aggregate | **Combinacional puro** | nenhum |
| `defuzzifier.vhd` | ms_defuzzify | Sequencial (multiplicação + divisão) | `start` + `done` |
| `adaptation_engine.vhd` | ms_adapt | FSM de 22 estados + divisor compartilhado | `start` + `busy` |