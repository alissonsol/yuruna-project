<a id="42ae9029-0001"></a>

# Projeto Modelo Yuruna

Estrutura de pastas para um novo projeto. Consulte
[architecture.md](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md) para
o modelo de três fases e os pontos de entrada da CLI, e a seção
Connectivity de [Soluções alternativas e FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md)
antes de implantar.

<a id="42ae9029-0002"></a>

## Implantação

Procure por `TO-SET` em `config/<cloud>/*.yml` e preencha os valores
obrigatórios; depois, na pasta `automation/` do framework (no seu clone
local de [yuruna](https://github.com/alissonsol/yuruna), não no repositório deste projeto):

```shell
Set-Resource.ps1  TO-SET localhost
Set-Component.ps1 TO-SET localhost
Set-Workload.ps1  TO-SET localhost
```

<a id="42ae9029-0003"></a>

## Preencher

- **Recursos** -- descrição dos recursos do projeto e saídas do OpenTofu.
- **Componentes** -- descrição dos componentes do projeto.
- **Cargas de trabalho** -- descrição das cargas de trabalho do projeto.
  O `config/localhost/workloads.yml` incluído é uma estrutura mínima
  (namespace + segredo de pull do registry + um espaço reservado
  `TO-SET`). Para um pipeline completo em localhost com TLS (mkcert), um
  ingress nginx e um emissor do cert-manager, copie e adapte
  [example/website](../../../example/website/config/localhost/workloads.yml).
- **Validação** -- como validar a funcionalidade do sistema.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.12

Voltar para [yuruna-project](../../../README.md) - [Yuruna](https://yuruna.com)
