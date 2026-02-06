## Docker

> `Docker/` klasöründe

- [[Docker Temelleri]] — Mimari, image, layer, Union FS, VM vs Container, lifecycle
- [[Docker Networking]] — Bridge, host, overlay, veth pair, iptables NAT, DNS
- [[Docker Storage ve Volumes]] — Bind mount, volume, tmpfs, persistence, backup
- [[Docker Compose]] — Multi-container, depends_on, healthcheck, .env, stack örneği
- [[Dockerfile Best Practices]] — Multi-stage build, cache, ENTRYPOINT vs CMD, non-root
- [[Docker Security]] — Seccomp, AppArmor, capabilities, read-only, rootless
- [[Container Runtime]] — dockerd → containerd → runc, OCI, nsenter

---

## Linux Internals

> `Linux/` klasöründe

### Temel Kavramlar
- [[Linux Namespaces]] — PID, network, mount, UTS, IPC, user, cgroup, time
- [[Linux IPC Mekanizmaları]] — Pipe, FIFO, shared memory, semaphore, message queue, socket, signal
- [[Linux Cgroups]] — cgroup v1/v2, CPU, memory, I/O, OOM Killer, PID limit
- [[Linux Process Management]] — fork, exec, signals, zombie process
- [[Linux File Permissions]] — DAC, SUID/SGID, sticky bit, ACL, capabilities

### Sistem Derinlikleri
- [[Linux Virtual Memory]] — Page table, TLB, mmap, CoW, swap, OOM Killer, ASLR
- [[Linux Filesystem Internals]] — VFS, inode, dentry, ext4/xfs/btrfs, journaling
- [[Linux Scheduler]] — CFS, nice, real-time policy, CPU affinity, cgroup bandwidth
- [[Linux Boot Process]] — BIOS/UEFI, GRUB2, kernel init, initramfs, systemd
- [[systemd Deep Dive]] — Unit/service/timer/target, journald, cgroup entegrasyonu

### Networking & Security
- [[iptables ve nftables]] — Packet filtering, NAT, Docker network kuralları
- [[TCP-IP Stack Internals]] — OSI/TCP-IP, socket buffer, TCP state machine, kernel tuning
- [[Linux Socket Programming]] — TCP/UDP server, epoll, non-blocking I/O, Unix domain socket
- [[Unix Domain Socket]] — AF_UNIX, fd passing (SCM_RIGHTS), credential, docker.sock, performans
- [[Linux Cryptography ve TLS]] — Symmetric/asymmetric, PKI, TLS handshake, OpenSSL, LUKS

### Araçlar & Gözlemleme
- [[Linux Logging]] — syslog, journald, dmesg, auditd, Docker log driver
- [[Linux Debugging Araçları]] — strace, ltrace, ptrace, gdb, perf, /proc debug
- [[Linux Dynamic Libraries]] — .so, ld.so, PLT/GOT, LD_PRELOAD, library injection
- [[eBPF]] — Kernel tracing, XDP, Cilium, bpftrace, güvenlik ve observability

---
