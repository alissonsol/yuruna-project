<a id="4255e584-0001"></a>

# yuruna-project

Repositório de projetos do [Yuruna](https://github.com/alissonsol/yuruna):
contém os recursos, componentes, cargas de trabalho e sequências de
teste do usuário, mantidos separados do framework para que os projetos
possam ser versionados e compartilhados de forma independente.

<a id="4255e584-0002"></a>

## Estrutura

- [template/](../../template/) -- estrutura de pastas para iniciar um novo
  projeto (resources / components / workloads / config).
- [example/](../../example/) -- exemplos de ponta a ponta que exercitam o
  framework em nuvens reais. Veja [Exemplos do Yuruna ...](../../example/README.md).
  - [example/website/](../../example/website/) -- contêiner de site em .NET C#
    implantado no Kubernetes em localhost, Azure ou AWS.
  - [example/text-to-sql/](../../example/text-to-sql/) -- **Versão inicial.**
    Text-to-SQL agêntico somente leitura em ASP.NET Core + PostgreSQL.
    Roda localmente e implanta pelo modelo completo de três fases do
    Yuruna; o Claude é ativado quando `ANTHROPIC_API_KEY` está definida.

<a id="4255e584-0003"></a>

## Saiba mais

- [Arquitetura](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md) do framework
- Conectividade e configuração: [Soluções alternativas e FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md)
- Contribuindo: [CONTRIBUTING.md](https://github.com/alissonsol/yuruna/blob/main/CONTRIBUTING.md)
- Segurança: [SECURITY.md](https://github.com/alissonsol/yuruna/blob/main/SECURITY.md)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.12

Voltar para [Yuruna](https://yuruna.com)
