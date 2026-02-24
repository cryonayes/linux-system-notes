# Linux Namespace ve IPC - Bash Komut Notları

Bu doküman, konuşmamızda geçen bash komutlarını sıralı bir şekilde toplar.

## 1) Namespace shell açma

```bash
sudo unshare --mount --uts --ipc --net --pid --fork --mount-proc bash
```

## 2) Network namespace oluşturma / girme / silme

```bash
sudo ip netns add ns1
sudo ip netns exec ns1 bash
sudo ip netns del ns1
```

## 3) Var olan bir process'in namespace'lerine girme

```bash
sudo nsenter -t <PID> -m -u -i -n -p bash
```

## 4) UTS izolasyonu (hostname) testi

```bash
hostname ns-test
hostname
```

```bash
sudo unshare --uts --fork bash -c 'echo before: $(hostname); hostname ns1; echo after: $(hostname); sleep 60'
```

Host terminalinde kontrol:

```bash
hostname
```

## 5) IPC izolasyonu testi (System V shared memory)

Host'ta bir shared memory oluştur:

```bash
ipcmk -M 1024
ipcs -m
```

Yeni IPC namespace aç:

```bash
sudo unshare --ipc --fork bash
```

İçeride kontrol et ve yeni obje oluştur:

```bash
ipcs -m
ipcmk -M 2048
ipcs -m
```

Host'ta tekrar kontrol:

```bash
ipcs -m
```

## 6) Oluşturulan System V shared memory segmentini silme

```bash
ipcs -m
ipcrm -m <shmid>
ipcrm -M <key>
ipcs -m
```

## 7) IPC bilgilerini kernel tarafında görme

System V IPC tablolarını /proc altında görebilirsin:

```bash
/proc/sysvipc/shm
/proc/sysvipc/sem
/proc/sysvipc/msg
```

## 8) POSIX shared memory nerede tutulur?

Linux'ta POSIX shared memory objeleri tipik olarak `/dev/shm` altında görünür (tmpfs).

Listelemek için:

```bash
ls -l /dev/shm
```

Programda şu şekilde bir obje oluşturduysan:

```c
shm_open("/my_shm", O_CREAT | O_RDWR, 0666)
```

Genelde şu path'te görürsün:

```bash
ls -l /dev/shm/my_shm
```

İçeriği incelemek için:

```bash
hexdump -C /dev/shm/my_shm | less
```

Silme (uygulama tarafı):

```c
shm_unlink("/my_shm");
```

Not: `ipcmk -M` ile oluşan System V segmentleri `/dev/shm` dosyası olarak görünmez.
---
