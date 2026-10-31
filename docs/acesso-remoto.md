# Acesso às câmeras fora de casa

## Recomendado: Tailscale (VPN)

Com uma VPN, o Mac, fora de casa, se comporta como se estivesse na rede da sua casa. O app funciona **sem nenhuma mudança** e com os mesmos IPs (192.168.x.x).

1. Instale o Tailscale ([tailscale.com](https://tailscale.com), plano grátis) em **um aparelho que fica sempre ligado em casa**: um Mac, um Raspberry Pi, um roteador compatível ou um NAS.
2. Nesse aparelho, anuncie a rede da casa como "subnet router":
   ```bash
   sudo tailscale up --advertise-routes=192.168.1.0/24
   ```
   Troque `192.168.1.0/24` pela faixa da sua rede.
3. No painel do Tailscale (admin console), aprove a rota anunciada.
4. Instale o Tailscale no Mac que você leva para fora e entre na mesma conta.
5. Abra o Amcrest Viewer. As câmeras aparecem como em casa.

Vantagens:

- Nada fica exposto na internet.
- O tráfego vai criptografado.
- Não depende da nuvem da Amcrest.

## Não recomendado: abrir portas no roteador

Redirecionar a porta 80/554 da câmera para a internet expõe a câmera a ataques. Firmwares de câmera têm histórico de falhas de segurança. Se for inevitável:

- use HTTPS e uma senha forte;
- mantenha o firmware atualizado;
- use uma porta externa diferente da padrão.

## Por que não o P2P da Amcrest

O acesso remoto do app oficial passa por um protocolo P2P proprietário (Amcrest Cloud/Dahua). Reproduzir esse protocolo exigiria engenharia reversa:

- ele muda sem aviso;
- provavelmente fere os termos de uso;
- o vídeo continuaria passando pelos servidores deles.

A VPN resolve o mesmo problema de forma estável e privada.
