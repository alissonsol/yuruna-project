<a id="42f64340-0001"></a>

# frontend/website

Frontend do site para autenticação de usuários e interface entre pessoas e computador.

<a id="client-side-libraries-libman"></a>

<a id="42f64340-0002"></a>

## Bibliotecas do lado do cliente (libman)

`wwwroot/lib/*` é ignorado pelo Git; as bibliotecas do lado do cliente declaradas em
`libman.json` são restauradas durante a compilação. O Docker faz isso
automaticamente (`Dockerfile` instala
`Microsoft.Web.LibraryManager.Cli` e executa `libman restore` antes de
`dotnet build`). Para executar `dotnet run` localmente, fora do Docker, faça a restauração
uma vez com:

```powershell
dotnet tool install -g Microsoft.Web.LibraryManager.Cli
libman restore
```

<a id="development-certificate"></a>

<a id="42f64340-0003"></a>

## Certificado de desenvolvimento

A imagem do contêiner não contém certificado nem senha. O Kestrel lê o PFX
de um arquivo montado pela plataforma e a senha de uma variável de ambiente,
para que nem este repositório, nem uma camada da imagem, nem um manifesto contenha
uma chave ou uma senha.

O exemplo procura a senha do seu PFX em dois lugares, nesta ordem:

1. A variável de ambiente `ASPNETCORE_Kestrel__Certificates__Default__Password`,
   quando não está vazia.
2. O arquivo de senha ao lado do PFX, `~/.aspnet/https/aspnetapp.pfx.password`, quando
   a variável não está definida: uma linha de texto simples (uma quebra de linha final é ignorada).
   Um arquivo vazio é considerado ausente.

Sem nenhuma das duas opções, o PFX é aberto sem senha, o que funciona apenas para um arquivo
exportado sem senha. A variável tem prioridade sempre que não está vazia, mesmo quando o arquivo contém
uma senha diferente.

Os convidados Ubuntu e Windows não precisam de nenhuma delas: seus scripts de provisionamento
`k8s` exportam `aspnetapp.pfx` com uma senha aleatória (32 bytes do gerador do sistema operacional,
representados por 64 caracteres hexadecimais) e a guardam em `aspnetapp.pfx.password`, criado com acesso
de leitura apenas para o proprietário (modo `600` no Ubuntu, uma ACL restrita ao usuário atual no Windows).
A senha nunca aparece na linha de comando nem na saída do script. Não há uma senha fixa em lugar algum:
um PFX sem arquivo de senha (por exemplo, um arquivo exportado com uma senha fixa) precisa ser substituído;
para isso, execute novamente a carga de trabalho `k8s`.

Na sua máquina, crie o certificado uma vez com uma senha de sua escolha:

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
$env:ASPNETCORE_Kestrel__Certificates__Default__Password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p $env:ASPNETCORE_Kestrel__Certificates__Default__Password
dotnet dev-certs https --trust
```

Se aparecer "A valid HTTPS certificate is already present" -> execute `dotnet dev-certs https --clean` e tente novamente.

Depois, mantenha essa senha na variável em cada shell que compila, implanta ou executa o
exemplo, ou salve-a uma vez no arquivo de senha e deixe a variável sem definição:

```powershell
Set-Content -LiteralPath $HOME/.aspnet/https/aspnetapp.pfx.password -Value $env:ASPNETCORE_Kestrel__Certificates__Default__Password
```

`dotnet dev-certs` grava a chave privada apenas quando `-p` é fornecido; sem ele,
o arquivo contém somente o certificado público e não pode servir HTTPS. Um PFX de outra ferramenta
também funciona, inclusive com senha vazia (deixe a variável e o arquivo de senha vazios ou ausentes).

<a id="where-the-certificate-goes"></a>

<a id="42f64340-0004"></a>

### Destino do certificado

| Execução | Certificado | Senha |
| --- | --- | --- |
| `docker-run-dev.ps1`, `docker-run-dev.cmd` | `~/.aspnet/https` montado somente para leitura em `/https` | a variável acima, passada ao Docker pelo nome; obtida de `aspnetapp.pfx.password` quando a variável não está definida |
| Cluster, `Set-Workload.ps1` | Secret do Kubernetes `website-pod-cert`, montado em `/https` | aleatória a cada implantação, lida por `secretKeyRef` |
| Automação sem certificado de desenvolvimento (`YURUNA_EXAMPLE_SELF_SIGNED_CERT=1`) | o mesmo Secret, contendo um certificado autoassinado descartável | a mesma |

Em um cluster, cada `config/<cloud>/workloads.yml` executa
[create-cert-secret.ps1](../../../../../../../example/website/components/frontend/website/create-cert-secret.ps1) imediatamente antes de instalar o
chart. O chart não pode ser instalado primeiro: `helm upgrade --install --atomic` espera pelo
pod, e o pod não pode iniciar sem seu Secret. O script abre seu PFX com
a senha do ambiente ou, quando ela não está definida, do arquivo de senha ao lado do PFX
(ou emite o certificado descartável), gera uma
senha com 256 bits aleatórios, exporta o certificado com essa senha e envia
o Secret para `kubectl create`.

O projeto mantém a senha fora de tudo que persiste ou é registrado em logs:

- Ela é gerada dentro do script, em memória. Não é uma variável de carga de trabalho (o
  mecanismo de implantação copia variáveis para `values.yaml`, o ambiente e os logs de depuração),
  nem um argumento de linha de comando (o mecanismo exibe um comando que falhou, e a lista
  de processos mostra os argumentos), nem um arquivo.
- O manifesto chega a `kubectl` pela entrada padrão. Usa-se `create` em vez de
  `apply` para que os dados não sejam copiados para uma anotação `last-applied-configuration`.
- Cada implantação exclui e recria seu namespace, portanto o Secret e sua senha
  duram exatamente uma implantação. A senha do seu próprio PFX é usada apenas para abrir esse arquivo;
  o cluster nunca a recebe.
- O pod monta apenas `aspnetapp.pfx`, legível pelo proprietário e pelo grupo (modo `0440`), e
  recebe a senha como variável de ambiente. O único processo da imagem é executado como
  root e lê o arquivo de qualquer forma; `fsGroup: 1654`, o ID que as imagens base .NET atribuem
  ao usuário e ao grupo sem privilégios de root, permite que esse usuário também o leia se a imagem passar a executar sem root.
- `.dockerignore` exclui `*.pfx`, `*.p12`, `*.pem` e `*.key`, para que uma chave esquecida
  na árvore de trabalho não alcance nenhuma etapa de compilação.

Apesar do nome, `copy-pfx.ps1` não copia nada (os testes do framework verificam o nome do arquivo);
ele apenas falha logo no início quando o certificado não pode ser usado. A automação define
`YURUNA_EXAMPLE_SELF_SIGNED_CERT=1` quando não existe certificado de desenvolvimento ou sua senha
é desconhecida, como fazem as cargas de trabalho dos convidados Ubuntu; o certificado descartável vale por 30 dias.

<a id="checking-an-image-and-a-deployment"></a>

<a id="42f64340-0005"></a>

### Verificação de uma imagem e de uma implantação

A imagem não deve conter chave nem senha. Após `Set-Component.ps1 website localhost`
(ou o script de carga de trabalho), com `IMAGE=localhost:5000/website/website:latest`:

```bash
# No layer instruction names key material: expect no output.
docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" | grep -i -E 'pfx|p12|\.pem|\.key'
# The application folder: expect no .pfx, .p12, .pem, or .key file.
docker run --rm --entrypoint ls "$IMAGE" -la /app
# Nothing key-shaped anywhere outside the CA bundle: expect no output.
docker run --rm --entrypoint sh "$IMAGE" -c "find / -xdev -type f \( -name '*.pfx' -o -name '*.p12' -o -name '*.key' -o -name '*.pem' \) -not -path '/etc/ssl/*' -not -path '/usr/share/ca-certificates/*' 2>/dev/null"
# No password variable is baked in: expect no ASPNETCORE_Kestrel entry.
docker image inspect --format '{{json .Config.Env}}' "$IMAGE"
```

O HTTPS deve continuar sendo servido a partir do Secret (use `-n text-to-sql` para o outro exemplo):

```bash
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
kubectl get secret website-pod-cert -n website -o jsonpath='{.data}'     # keys: aspnetapp.pfx, password
kubectl get deployment website -n website -o jsonpath='{.spec.template.spec.containers[0].env}'   # secretKeyRef, no literal value
kubectl exec -n website deploy/website -- ls -lL /https                  # only aspnetapp.pfx, mode -r--r-----
kubectl port-forward -n website svc/website 8443:443 &
curl -ksS -o /dev/null -w '%{http_code}\n' https://localhost:8443/       # 200
echo | openssl s_client -connect localhost:8443 2>/dev/null | openssl x509 -noout -subject -dates
curl -ksS -o /dev/null -w '%{http_code}\n' http://localhost/             # 200 through the ingress, as test-localhost.sh checks
```

A espera pela disponibilidade é a verificação mais forte: a sonda de prontidão faz uma requisição HTTPS à porta 443,
portanto ela só passa quando o Kestrel carregou o PFX com a senha do Secret.

<a id="regenerating-and-modifying-the-website-project"></a>

<a id="42f64340-0006"></a>

## Regeneração e modificação do projeto do site

- Projeto criado com [Tutorial: introdução ao ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/getting-started/?view=aspnetcore-10.0):
  - Em `components/frontend`: `dotnet new webapp -o website`
  - Adicione `**/wwwroot/lib/*` a `.gitignore`.
- Coloque em um contêiner conforme [Execução de imagens de contêiner pré-compiladas com HTTPS](https://learn.microsoft.com/en-us/aspnet/core/security/docker-https?view=aspnetcore-10.0):
  - Se `Microsoft.VisualStudio.Azure.Containers.Tools.Targets` estiver ausente: `dotnet add package Microsoft.VisualStudio.Azure.Containers.Tools.Targets --version 1.23.0`.
  - Clique com o botão direito no projeto -> `Add -> Docker Support...` (requer o [Visual Studio](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/docker/visual-studio-tools-for-docker?view=aspnetcore-10.0)).
- Teste com `IIS Express` e depois com a versão `Docker`:
  - "Volume sharing is not enabled" -> Docker Desktop -> Settings -> Resources -> File Sharing -> adicione `C:\` -> Apply & Restart.
  - Tanto a compilação Linux quanto o depurador do Visual Studio usam `Dockerfile`.

<a id="running-the-docker-image-locally"></a>

<a id="42f64340-0007"></a>

## Execução local da imagem Docker

<a id="42f64340-0008"></a>

### Docker

- Inicie a compilação Docker pelo depurador do VS -- executa como `website:dev`, com o nome `website`. Parar o depurador pode deixar o contêiner em execução; faça a limpeza.
- Ou use [docker-run-dev.ps1](../../../../../../../example/website/components/frontend/website/docker-run-dev.ps1): compila `yrn42website-prefix/website:latest`, executa como `yrn42website-prefix-example-website` e monta `~/.aspnet/https` somente para leitura. Ele para antes da compilação quando o certificado não pode ser aberto com a senha de `ASPNETCORE_Kestrel__Certificates__Default__Password` ou, quando ela não está definida, de `~/.aspnet/https/aspnetapp.pfx.password`; quando a variável não está definida, cada script lê esse arquivo para seu próprio ambiente durante a execução, para que o Docker continue recebendo a senha pelo nome, sem exibir nenhum valor. [docker-run-dev.cmd](../../../../../../../example/website/components/frontend/website/docker-run-dev.cmd) faz o mesmo sem a verificação inicial. Abra `http://localhost:8000/` ou `https://localhost:8001/`.
- Ou compile com `Set-Component.ps1 website localhost` e depois execute de forma interativa (a variável de senha é passada pelo nome, portanto seu valor não é digitado aqui):

  ```
  docker run --rm -it -p 8000:80 -p 8001:443 --name "test-website" \
    -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 \
    -e ASPNETCORE_Kestrel__Certificates__Default__Password \
    -e ASPNETCORE_Kestrel__Certificates__Default__Path=/https/aspnetapp.pfx \
    -v "$HOME/.aspnet/https:/https:ro" \
    localhost:5000/website/website:latest
  ```

<a id="kubernetes-docker-desktop-cluster"></a>

<a id="42f64340-0009"></a>

### Kubernetes (cluster docker-desktop)

```bash
# After Set-Component.ps1 website localhost
pwsh ./create-cert-secret.ps1 -Namespace default -SecretName website-pod-cert
kubectl apply -f website-pod.yaml
kubectl apply -f website-service.yaml
kubectl port-forward services/website-service 8000:80 8001:443 -n default
# Open http://localhost:8000/
kubectl delete svc website-service
kubectl delete pod website-pod
kubectl delete secret website-pod-cert
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.04

Back to [Website example](../../../../../../../example/website/README.md) - [yuruna-project](../../../../../../../README.md) - [Yuruna](https://yuruna.com)
