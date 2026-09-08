<a id="42916cfc-0001"></a>

# Exemplo de site Yuruna

Um contêiner simples de site .NET C# implantado no Kubernetes.

<a id="42916cfc-0002"></a>

## Implantação

Antes de implantar, procure por `TO-SET` em `config/<cloud>/*.yml`, preencha
os valores necessários (veja [Nuvem](#nuvem) abaixo) e leia a seção
Connectivity de [Soluções alternativas e FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md).

Na pasta `automation/` (no `pwsh`):

```shell
Set-Resource.ps1  website localhost
Set-Component.ps1 website localhost
Set-Workload.ps1  website localhost
```

Veja [architecture.md](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md)
para o modelo de três fases e os pontos de entrada da CLI.

<a id="42916cfc-0003"></a>

## O que este projeto contém

- **Recursos** -- um cluster Kubernetes, um registro de contêineres, um
  IP público. O OpenTofu gera `${env:registryName}.registryLocation`,
  `${env:contextName}.frontendIp`, `${env:contextName}.hostname`.
- **Componentes** -- uma imagem Docker do site .NET C# e o NGINX Ingress
  Controller ([chart do Helm](https://kubernetes.github.io/ingress-nginx/deploy/#using-helm)).
- **Cargas de trabalho** -- frontend/website e o ingress NGINX roteando o
  tráfego para o site.

<a id="42916cfc-0004"></a>

## Validação

- Abra o endpoint exibido após a publicação das cargas de trabalho.
- `kubectl get services --all-namespaces`
- `kubectl get events --all-namespaces`

<a id="42916cfc-0005"></a>

## Nuvem

Antes do `Set-Workload.ps1`, confirme se a entrada DNS `yrn42website-domain`
(por exemplo, `www.yrn42.com`) aponta para o `frontendIp` gerado pelo
`Set-Resource.ps1`. Alternativas:

- `curl -v http://{frontendIp} -H 'Host: {yrn42website-domain}'`
- Uma entrada temporária em `/etc/hosts`.

<a id="42916cfc-0006"></a>

### Azure

- Escolha um nome de registro globalmente único -- faça ping em
  `yourname.azurecr.io` para confirmar que está livre -- e então substitua
  `localhost` por `azure`.
- Se o `EXTERNAL-IP` em `nginx-ingress` nunca aparecer e os eventos
  mencionarem `Error syncing load balancer: failed to ensure load balancer:
  ensurePublicIPExists ...`, verifique se `azure-dns-label-name` na
  implantação do Helm corresponde ao rótulo `frontendIp` (nome do cluster).
- Executar `workloads` novamente pode remover o IP; bloqueie o recurso
  conforme descrito [nesta questão](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.08

Voltar para [yuruna-project](../../../../README.md) - [Yuruna](https://yuruna.com)
