<a id="42b9e3dc-0001"></a>

# Exemplos do Yuruna

**NOTA**: Como alguns exemplos compartilham o mesmo componente de
ingress e o mesmo namespace, implantar um deles pode substituir outro.
Para restaurar o exemplo que funcionava antes, reimplante suas regras
de ingress. Consulte a seção Connectivity do
[Soluções alternativas e FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md).

<a id="42b9e3dc-0002"></a>

## Teste básico de ponta a ponta

- [website](../../../example/website/README.md): um contêiner simples de site .NET C# implantado em um cluster Kubernetes.

<a id="42b9e3dc-0003"></a>

## Exemplos em estágio inicial

- [text-to-sql](../../../example/text-to-sql/README.md) -- **Versão inicial.** Text-to-SQL
  agêntico somente leitura em ASP.NET Core + PostgreSQL. Executa
  localmente e implanta pelo modelo completo de três fases do Yuruna
  (`Set-Resource` / `Set-Component` / `Set-Workload`); o Claude é
  ativado quando `ANTHROPIC_API_KEY` está definida.

<a id="42b9e3dc-0004"></a>

## Modelo

- A [estrutura de pastas](../../../template/) para criar um novo projeto: copie-a
  para uma nova pasta, faça as alterações necessárias e adicione o código do
  componente (procure por `TO-SET`).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.12

Voltar para [yuruna-project](../../../README.md) - [Yuruna](https://yuruna.com)
