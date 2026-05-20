# CLAUDE.md — Sistema Fuzzy Adaptativo em VHDL

---

## Instrucoes para o Claude (leia primeiro)

> **Este arquivo e o seu repositorio de conhecimento persistente sobre este projeto.**
>
> - **Consulte este arquivo no inicio de cada sessao** antes de qualquer tarefa.
> - **Atualize este arquivo apos qualquer mudanca significativa:** novo arquivo VHDL, alteracao de interface de componente, mudanca de FSM, ajuste no mapa de registradores, novo resultado de sintese, ou decisao de arquitetura relevante.
> - **Nao duplique** o que ja esta aqui — edite a secao relevante.
> - Seccoes marcadas com `[VERIFICAR]` indicam que o estado real pode ter divergido; releia o arquivo antes de confiar.
> - Mantenha o arquivo conciso e factual. Sem especulacoes.

---

## 1. Visao Geral do Projeto

**Titulo:** Sistema de Inferencia Fuzzy Adaptativo para Recursos Genericos
**Contexto:** TCC (Trabalho de Conclusao de Curso)
**Origem:** Portagem de um sistema Python (`adaptative_fuzzy_system.py`) para hardware VHDL em FPGA

**Proposito:** Classificar dois sinais de sensor (`sensor1`, `sensor2`) em tres classes (`OK`, `ALERT`, `CRITICAL`) usando logica fuzzy Mamdani, com adaptacao online dos parametros das funcoes de pertinencia via algoritmo de Welford + EMA.

**FPGA alvo:** Intel Cyclone V — `5CGXFC7C7F23C8`
**Ferramenta:** Quartus Prime 22.1std.1 Lite Edition
**Clock:** 50 MHz
**Simulacao:** ModelSim (VHDL)

> **MUDANCA ARQUITETURAL (15/03/2026):** UART, CAN e SPI removidos. Configuracao agora e feita via bus generico `cfg_we/cfg_addr/cfg_data`. Ver secao 3 e 9.

---

## 2. Resultado de Sintese (ultima compilacao bem-sucedida)

| Recurso | Usado | Total | % |
|---|---|---|---|
| ALMs (logica) | 3.446 | 56.480 | 6% |
| Registradores | 2.196 | — | — |
| Pinos | 119 | 268 | 44% |
| DSP Blocks | 13 | 156 | 8% |
| Block RAM | 0 | — | 0% |

> Compilacao bem-sucedida em 27/02/2026. `.sof` gerado em `output_files/`.

---

## 3. Arquitetura SOA (padrao do projeto)

O projeto segue um padrao **Service-Oriented Architecture** mapeado em hardware:

| Papel SOA | Arquivo |
|---|---|
| **Top-level do sistema** (entidade Quartus) | `system_top.vhd` |
| **Service Requester** (cliente) | `ms_client.vhd` |
| **Service Broker** (orquestrador) | `ms_broker.vhd` |
| **Service Registry** | `config_registers.vhd` |
| **Fuzzy Service** (servico composto) | `svc_fuzzy.vhd` |
| **Adapt Service** (servico de adaptacao) | `svc_adapt.vhd` |
| ms_fuzzify (x2, paralelo) | `ms_fuzzify.vhd` |
| bloco interno do ms_fuzzify | `triangular_mf.vhd` |
| ms_rule_eval | `ms_rule_eval.vhd` |
| ms_aggregate | `ms_aggregate.vhd` |
| ms_defuzzify | `ms_defuzzify.vhd` |
| ms_adapt | `ms_adapt.vhd` |

**Hierarquia de composicao:**
```
system_top
  ├── ms_client        (Service Requester)
  └── ms_broker        (Service Broker)
        ├── config_registers  (Service Registry)
        ├── svc_fuzzy         (Fuzzy Service — composto)
        │     ├── ms_fuzzify x2
        │     ├── ms_rule_eval
        │     ├── ms_aggregate
        │     └── ms_defuzzify
        └── svc_adapt         (Adapt Service)
              └── ms_adapt
```

> `ms_config_uart`, `ms_config_can`, `ms_config_spi`, `ms_config_arbiter` **REMOVIDOS** em 15/03/2026.
> `fuzzy_top.vhd` **REMOVIDO** em 15/03/2026 — substituido por `ms_broker.vhd`.

---

## 4. Aritmetica: Ponto Fixo Q8.8

**Todos os sinais de dados** sao `signed(15 downto 0)` em formato Q8.8:
- 8 bits inteiros + 8 bits fracionarios
- `1.0 = 256 (0x0100)`, `0.5 = 128 (0x0080)`
- Intermediarios de multiplicacao: `signed(31 downto 0)` em Q16.16
- Divisao feita com shift do numerador: `numerador << 8` antes de dividir

---

## 5. Mapa de Registradores (`config_registers.vhd`)

33 registradores de 16 bits (`signed`, Q8.8). Duas portas de escrita; UART tem prioridade.

| Endereco (int) | Hex | Conteudo |
|---|---|---|
| 0 | `0x00` | `in1_a_low` |
| 1 | `0x01` | `in1_b_low` |
| 2 | `0x02` | `in1_c_low` |
| 3 | `0x03` | `in1_a_med` |
| 4 | `0x04` | `in1_b_med` |
| 5 | `0x05` | `in1_c_med` |
| 6 | `0x06` | `in1_a_high` |
| 7 | `0x07` | `in1_b_high` |
| 8 | `0x08` | `in1_c_high` |
| 9..17 | `0x09..0x11` | Idem para Input 2 |
| 18..26 | `0x12..0x1A` | `rule_class_0..8` (2 bits LSB: 00=OK, 01=ALERT, 10=CRIT) |
| 27 | `0x1B` | `out_val_ok` |
| 28 | `0x1C` | `out_val_alert` |
| 29 | `0x1D` | `out_val_crit` |
| 30 | `0x1E` | `adapt_alpha` (taxa EMA, ex: 0.05 = 13) |
| 31 | `0x1F` | `adapt_every_n` (frequencia de adaptacao) |
| 32 | `0x20` | `adapt_spread_k` (fator k, ex: 1.0 = 256) |

**Restricao critica:** `ms_adapt` so pode escrever nos enderecos `0x00..0x11` (parametros MF). Enderecos `0x12..0x20` so sao escritos pela UART.

---

## 6. Pipeline de Inferencia (FSMs do `ms_broker.vhd` e `svc_fuzzy.vhd`)

**FSM do `ms_broker.vhd`** (6 estados):
```
S_IDLE
  │ start=1
  ▼
S_FUZZY_START   ← pulso fuzzy_start=1 ao svc_fuzzy (1 ciclo)
  ▼
S_FUZZY_WAIT    ← aguarda fuzzy_done=1 do svc_fuzzy
  ▼
S_OUTPUT        ← entrega result_valid=1, result_class, result_value
  ▼
S_ADAPT_START   ← pulso adapt_start=1 ao svc_adapt (1 ciclo)
  ▼
S_ADAPT_WAIT    ← aguarda adapt_busy=0
  ▼
S_IDLE
```

**FSM interna do `svc_fuzzy.vhd`** (6 estados):
```
S_IDLE
  │ start=1
  ▼
S_FUZZ_START    ← pulso fuzz_start=1 aos dois ms_fuzzify (1 ciclo)
  ▼
S_FUZZ_WAIT     ← aguarda fuzz1_done AND fuzz2_done
  ▼              (ms_rule_eval e ms_aggregate ja calcularam — combinacional)
S_DEFUZZ_START  ← pulso defuzz_start=1 ao ms_defuzzify (1 ciclo)
  ▼
S_DEFUZZ_WAIT   ← aguarda defuzz_done=1
  ▼
S_OUTPUT        ← emite done=1, result_class, result_value (1 ciclo)
  ▼
S_IDLE
```

**Observacoes criticas:**
- Os dois fuzzifiers rodam em **paralelo** — mesmo `fuzz_start`, aguarda ambos `done`.
- `ms_rule_eval` e `ms_aggregate` sao **puramente combinacionais** — nenhum estado de espera dedicado.
- `svc_adapt` roda **fora do caminho critico** da inferencia — ms_broker espera em S_ADAPT_WAIT.

---

## 7. Descricao dos Arquivos VHDL

### `system_top.vhd` — Top-level do sistema (entidade Quartus)
- Instancia `ms_client` (Requester) e `fuzzy_top` (Broker) e faz o wiring entre eles.
- **Sem generics** (UART/CAN removidos em 15/03/2026).
- Portas externas: `clk`, `rst`, `cfg_we`, `cfg_addr(7:0)`, `cfg_data(15:0)`, `sensor1_in`, `sensor2_in`, ranges `in1/2_min/max`, `request`, `classification(1:0)`, `value_out(15:0)`, `done`

---

### `ms_client.vhd` — Service Requester
- Amostra dados de sensor externos, gerencia o handshake com o Broker.
- FSM de 4 estados: `S_IDLE → S_SEND → S_WAIT → S_DONE`
- Em `S_IDLE`: trava `sensor1/2_in` e ranges em registradores internos ao detectar `request=1`
- Em `S_SEND`: emite `start=1` por 1 ciclo ao Broker
- Em `S_WAIT`: aguarda `result_valid` do Broker
- Em `S_DONE`: armazena resultado em `classification`/`value_out`, emite `done=1` por 1 ciclo
- Nao embute logica de dominio — genericamente aplicavel a qualquer sensor Q8.8

---

### `ms_broker.vhd` — Service Broker
- **Orquestra** `config_registers`, `svc_fuzzy` e `svc_adapt`.
- **Sem generics** (UART/CAN removidos em 15/03/2026).
- Portas externas: `clk`, `rst`, `cfg_we`, `cfg_addr(7:0)`, `cfg_data(15:0)`, `sensor1_data(15:0)`, `sensor2_data(15:0)`, `in1_min_val`, `in1_max_val`, `in2_min_val`, `in2_max_val`, `start`, `result_class(1:0)`, `result_value(15:0)`, `result_valid`
- FSM de 6 estados (ver secao 6)
- Le todos os parametros do `config_registers` e os roteia para `svc_fuzzy` e `svc_adapt`
- Nao contem logica fuzzy — puramente orquestracao de servicos

---

### `svc_fuzzy.vhd` — Fuzzy Service (servico composto)
- Encapsula: `ms_fuzzify x2`, `ms_rule_eval`, `ms_aggregate`, `ms_defuzzify`
- FSM interna de 6 estados (ver secao 6)
- Recebe: todos os parametros MF, classes de regras, val_ok/alert/crit, sensor data
- Emite: `done` (1 ciclo), `result_class(1:0)`, `result_value(15:0)`
- Capture de done dos fuzzifiers via sinais `fuzz1_done`, `fuzz2_done` (reset no S_FUZZ_START)

---

### `svc_adapt.vhd` — Adapt Service
- Wrapper fino sobre `ms_adapt`
- Expoe: `start`, `busy`, sensor values, cfg params (alpha/N/k), parametros MF atuais, ranges
- Saidas de escrita ao registry: `adapt_wr_en`, `adapt_wr_addr(7:0)`, `adapt_wr_data(15:0)`
- Sem FSM propria — delega inteiramente ao `ms_adapt`

---

### `config_registers.vhd` — Service Registry
- Array de 33 registradores: `regs : array(0 to 32) of std_logic_vector(15 downto 0)`
- Escrita sincrona, 2 portas: `write_en` (UART, prioridade) e `adapt_wr_en` (ms_adapt)
- Leitura puramente combinacional (saidas mapeadas diretamente)
- Nenhuma logica de processamento — repositorio passivo

---

### `ms_fuzzify.vhd` — ms_fuzzify (x2)
- Instancia 3 `triangular_mf` em paralelo (LOW, MED, HIGH)
- Sincronizacao de done com registradores `done_low_r`, `done_med_r`, `done_high_r`
- Reset dos registradores de done no pulso `start` (nao no rst)
- `done` = AND combinacional dos 3 registradores de done
- Instanciado 2x no top com mesmo `fuzz_start`

---

### `triangular_mf.vhd` — bloco interno
- FSM: `S_IDLE → S_EVAL → S_DIV → S_DONE`
- Divisor **restoring division** em `DIV_BITS = 24` ciclos
- Numerador: `(numerador_Q8.8) & x"00"` = 24 bits (shift left 8)
- Casos tratados: ombro esquerdo (`a==b`), ombro direito (`b==c`), triangulo geral
- Resultado limitado a `1.0 (256)` no estado `S_DIV`
- `done` e `mu` so sao atualizados no estado `S_DONE` (1 ciclo); depois retorna a `S_IDLE`

---

### `ms_rule_eval.vhd` — ms_rule_eval
- **Puramente combinacional** — sem clock inputs relevantes
- 9 comparadores MIN em paralelo: `strength_i = MIN(mu1_X, mu2_Y)`
- Mapeamento fixo 3x3 (LOW/MED/HIGH × LOW/MED/HIGH)
- Operador AND de Mamdani implementado como funcao `fn_min`

---

### `ms_aggregate.vhd` — ms_aggregate
- **Puramente combinacional** — processo sensivel a todos os sinais de entrada
- Calcula MAX das forcas por classe de saida (`agg_ok`, `agg_alert`, `agg_critical`)
- Usa variaveis locais e loop `for i in 0 to 8` (sintetizavel)
- Classes: `"00"=OK`, `"01"=ALERT`, `"10"=CRITICAL`

---

### `ms_defuzzify.vhd` — ms_defuzzify
- FSM: `S_IDLE → S_MULTIPLY → S_DIVIDE → S_CLASSIFY → S_DONE`
- Multiplicacao 16x16→32 no estado `S_MULTIPLY` (1 ciclo, mapeado para DSP)
- Divisao restoring 32-bit no estado `S_DIVIDE` (~34 ciclos)
- Trick de inicializacao: detecta inicio da divisao por `div_count=0 AND div_dividend=0 AND div_quotient=0 AND div_remainder=0`
- **CRITICO:** Os sinais do divisor (`div_dividend`, `div_divisor`, `div_quotient`, `div_remainder`, `div_count`) DEVEM ser resetados no bloco `if rst='1'`. Sem isso, na primeira inferencia pos-reset os sinais sao 'U', a condicao de inicializacao falha mas o `elsif div_count=0` dispara erroneamente com `div_quotient='U'`, classificando como CRITICAL.
- Output default quando pesos = 0: `0.5 = 128`
- Classificacao: `crisp <= val_ok → OK`, `crisp <= val_alert → ALERT`, `else → CRITICAL`
- Resets os sinais do divisor no estado `S_DONE` para proxima operacao (e tambem no rst)

---

### `ms_adapt.vhd` — ms_adapt
- FSM de **22 estados** com divisor sequencial compartilhado
- **Interface de controle:** `start` (pulso de entrada), `busy` (nivel de saida)
- **Algoritmo completo:**
  1. **WELFORD_1..6**: Atualiza `n`, `mean`, `m2` para ambos inputs (algoritmo de Welford online)
  2. **CHECK_ADAPT**: Verifica `n % N == 0` via contador `adapt_counter`; se nao, vai direto para `S_DONE`
  3. **VARIANCE_1..2**: `var = m2 / (n-1)` — resultado extraido como `div_quotient(23 downto 8)` (Q16.16→Q8.8)
  4. **SQRT_1_INIT/ITER + SQRT_2_INIT/ITER**: Raiz quadrada digit-by-digit (nao Newton-Raphson como descrito no .md antigo) — 12 iteracoes, 2 bits/ciclo, input escalado `abs(var)<<8` (24 bits)
  5. **CALC_TARGETS_1..2**: `p1 = mean - k*std`, `p2 = mean`, `p3 = mean + k*std` com clamp
  6. **EMA_1..2**: `p_new = p_current + alpha * (p_target - p_current)`, shift right 8 para Q8.8
  7. **DERIVE_1..2**: LOW=(min,min,p1), MED=(2p1-p2, p2, 2p3-p2), HIGH=(p3,max,max)
  8. **WRITE_REGS**: 18 escritas nos config_registers (1 por ciclo, enderecos 0..17)
  9. **DONE**: `busy <= 0`, volta a `S_IDLE`
- Divisor sequencial compartilhado (`div_start/busy/done` + 32-bit restoring)
- Funcoes auxiliares internas: `fn_min`, `fn_max`, `fn_clamp`
- `min_sep = range >> 4` (~6.25% do range) como separacao minima entre pontos de controle
- **EMA usa os parametros atuais dos registradores** como `p_current` (`in1_c_low` para p1, `in1_b_med` para p2, `in1_a_high` para p3 — e idem para input2)

---

## 8. Loop de Adaptacao (realimentacao implicita)

```
Ciclo N:    ms_adapt le MF params do config_registers
            → calcula novos params (Welford + sqrt + EMA + derivacao)
            → escreve 18 novos params no config_registers (0x00..0x11)

Ciclo N+1:  ms_fuzzify le MF params atualizados do config_registers
            → inferencia com novo comportamento
```

`ms_adapt` e `ms_fuzzify` nunca se comunicam diretamente — o `config_registers` e o ponto de encontro.

---

## 9. Interface de Configuracao Generica (cfg bus)

Para escrever no registrador de endereco `ADDR` o valor `DATA` (16 bits Q8.8):
- Aplicar `cfg_addr=ADDR`, `cfg_data=DATA`, `cfg_we='1'` por 1 ciclo de clock.
- Rebaixar `cfg_we='0'` no ciclo seguinte.
- Config completa (33 registradores) leva 66 ciclos (1 write + 1 idle por reg).

O `tb_fuzzy_pkg.vhd` exporta `configure_system(cfg_we, cfg_addr, cfg_data)` que faz a carga automaticamente nos testbenches.

---

## 10. Convencoes e Padroes do Codigo

- **Todos os sinais de dados de saida** sao `out signed(15 downto 0)` em Q8.8
- **Classes de saida** sao `std_logic_vector(1 downto 0)`: `"00"=OK`, `"01"=ALERT`, `"10"=CRITICAL`
- **Pulsos de start/done** sempre duram 1 ciclo de clock
- **Reset sincrono** em todos os componentes (borda de subida, `if rst = '1'`)
- **`done` e zero por default** no inicio de cada processo; so vai a `1` no ciclo correto
- Divisao sempre implementada como **restoring division** sequencial (nao usa IP core)
- Multiplicacoes Q8.8 × Q8.8 → Q16.16 (32 bits) mapeiam para **DSP blocks** do FPGA
- Componentes declarados localmente na `architecture` de `fuzzy_top` (sem `package`)
- Nomenclatura de sinais internos: prefixo `cfg_` para saidas do config_registers, `mu1_`/`mu2_` para graus de pertinencia, `str` para strengths, `agg_` para agregados

---

## 11. Arquivos do Projeto

| Arquivo | Tipo | Ultima modificacao relevante |
|---|---|---|
| `system_top.vhd` | VHDL top-level (Quartus) | 15/03/2026 |
| `ms_client.vhd` | VHDL Service Requester | 07/03/2026 |
| `ms_broker.vhd` | VHDL Service Broker | 15/03/2026 |
| `svc_fuzzy.vhd` | VHDL Fuzzy Service (composto) | 15/03/2026 |
| `svc_adapt.vhd` | VHDL Adapt Service (wrapper) | 15/03/2026 |
| `config_registers.vhd` | VHDL Service Registry | 15/03/2026 |
| `ms_adapt.vhd` | VHDL | 27/02/2026 |
| `ms_fuzzify.vhd` | VHDL | 27/02/2026 |
| `triangular_mf.vhd` | VHDL | 01/02/2026 |
| `ms_rule_eval.vhd` | VHDL | 01/02/2026 |
| `ms_aggregate.vhd` | VHDL | 01/02/2026 |
| `ms_defuzzify.vhd` | VHDL | 01/02/2026 |
| `tb_fuzzy_pkg.vhd` | VHDL package testbenches | 15/03/2026 |
| `testbench_servidor_idle.vhd` | VHDL testbench regressao | 15/03/2026 |
| `testbench_cenario_alerta.vhd` | VHDL testbench regressao | 15/03/2026 |
| `testbench_predial_ok.vhd` | VHDL cenario predial OK | 15/03/2026 |
| `testbench_predial_critico.vhd` | VHDL cenario predial CRITICO | 15/03/2026 |
| `testbench_clima_ok.vhd` | VHDL cenario clima OK | 15/03/2026 |
| `testbench_clima_alerta.vhd` | VHDL cenario clima ALERTA | 15/03/2026 |
| `testbench_adaptacao.vhd` | VHDL testbench adaptacao online | 21/04/2026 |
| `sim_adaptacao.do` | ModelSim script adaptacao | 21/04/2026 |
| `sim_idle.do` / `sim_alerta.do` | ModelSim scripts regressao | 15/03/2026 |
| `sim_predial_ok.do` / `sim_predial_critico.do` | ModelSim scripts predial | 15/03/2026 |
| `sim_clima_ok.do` / `sim_clima_alerta.do` | ModelSim scripts clima | 15/03/2026 |
| `adaptative_fuzzy.qsf` | Quartus settings | 07/03/2026 — [VERIFICAR pins apos re-sintese] |
| `adaptative_fuzzy.qpf` | Quartus project | 26/02/2026 |
| `output_files/` | Artefatos de sintese | — |

---

## 12. Pontos de Atencao e Armadilhas Conhecidas

1. **`ms_defuzzify.vhd` — deteccao de inicio da divisao:** usa a condicao composta `div_count=0 AND div_dividend=0 AND div_quotient=0 AND div_remainder=0` para distinguir "primeira entrada no estado S_DIVIDE" de "divisao em andamento". Os sinais do divisor DEVEM estar no bloco `if rst='1'` (corrigido em 28/02/2026); sem isso, a primeira inferencia classifica erroneamente como CRITICAL.

2. **`ms_adapt.vhd` — bugs corrigidos em 21/04/2026 (descobertos pelo testbench_adaptacao):**
   - **Bug 1 (ordem de condição do divisor):** `div_done='1'` e `div_busy='0'` ocorrem simultaneamente; o `elsif div_done` nunca era alcançado — divisão reiniciava infinitamente. Fix: checar `div_done='1'` PRIMEIRO nos 4 estados (S_WELFORD_2, S_WELFORD_5, S_VARIANCE_1, S_VARIANCE_2).
   - **Bug 2 (slice errado do quociente):** `div_quotient(15 downto 0)` em vez de `(23 downto 8)` — média 256× maior que o correto, parâmetros subiam em vez de descer. Fix: usar `div_quotient(23 downto 8)` em S_WELFORD_2 e S_WELFORD_5.
   - Regressão completa executada após as correções: todos os 6 testbenches estáticos continuaram passando.

3. **`ms_adapt.vhd` — sqrt por digit-by-digit, nao Newton-Raphson:** o comentario no header do arquivo menciona "Newton-Raphson", mas o codigo implementa digit-by-digit com 12 iteracoes.

3. **`ms_adapt.vhd` — `adapt_wr_en` so escreve em 0x00..0x11:** `config_registers` tem hardcoded `if addr_int >= 0 and addr_int <= 17`. A engine de adaptacao nunca deve tentar escrever fora desse range.

4. **`ms_fuzzify.vhd` — reset dos `done_r` no `start`, nao no `rst`:** o processo reseta `done_low_r/med_r/high_r` quando `rst='1' OR start='1'`. Comportamento intencional.

5. **Prioridade de escrita no registry:** cfg bus (porta 1) tem prioridade sobre svc_adapt (porta 2). Implementado via `elsif` — cfg bus ganha em conflito. Conflito e improvavel em operacao normal (configuracao ocorre antes da inferencia).

6. **`system_top.vhd` e a entidade top-level do Quartus:** o `.qsf` foi atualizado manualmente para apontar para `system_top` (feito em 07/03/2026).

7. **Ranges das variaveis de entrada:** `in1_min_val`, `in1_max_val`, `in2_min_val`, `in2_max_val` sao passados pelo `ms_client` ao `ms_broker` (nao vem do registry). Necessarios para o `svc_adapt`/`ms_adapt` calcular constraints dos pontos de controle.
