"""Faux matériel de verify.sh : simule le branchement et le débranchement de webcams USB.

Tourne dans le conteneur lmt-hw, qui monte trois volumes de test :
  /fakesys  un sysfs minimal de la forme de celui de l'hôte (lu par lab-media-auth et la capture)
  /fakedev  les nœuds videoN (vus par la capture sous /hostdev)
  /fakesnd  les nœuds pcmC<N>D0c (vus par la capture sous /dev/snd)

Les nœuds sont de VRAIS nœuds caractère (mknod, majeurs 81 et 116) mais sur des mineurs à partir
de 200, qui n'existent pas sur l'hôte : rien ne peut s'ouvrir, et la capture de test (mode
testsrc) n'ouvre de toute façon aucun périphérique.

usage :
  fakehw.py plug <port> [--vid V] [--pid P] [--product TEXTE] [--serial TEXTE] [--mic]
  fakehw.py unplug <port>        fakehw.py unplug-all        fakehw.py ls
"""
import argparse
import os
import shutil
import stat

SYS, DEV, SND = '/fakesys', '/fakedev', '/fakesnd'


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(text.encode('utf-8', 'surrogateescape') + b'\n')


def link(cls, name, target):
    d = os.path.join(SYS, 'class', cls)
    os.makedirs(d, exist_ok=True)
    os.symlink(os.path.relpath(target, d), os.path.join(d, name))


def next_minor(kind):
    path = os.path.join(SYS, f'.next-{kind}')
    try:
        value = int(open(path).read())
    except OSError:
        value = 200
    open(path, 'w').write(str(value + 1))
    return value


def plug(a):
    dev = os.path.join(SYS, 'devices', 'usb9', a.port)
    if os.path.exists(dev):
        raise SystemExit(f'{a.port} déjà branché')
    w(os.path.join(dev, 'idVendor'), a.vid)
    w(os.path.join(dev, 'idProduct'), a.pid)
    w(os.path.join(dev, 'product'), a.product)
    if a.serial is not None:
        w(os.path.join(dev, 'serial'), a.serial)
    iface = os.path.join(dev, f'{a.port}:1.0')
    w(os.path.join(iface, 'bInterfaceClass'), '0e')
    for index in (0, 1):                          # capture, puis métadonnées
        minor = next_minor('video')
        name = f'video{minor}'
        node = os.path.join(iface, 'video4linux', name)
        w(os.path.join(node, 'index'), str(index))
        w(os.path.join(node, 'dev'), f'81:{minor}')
        os.mknod(os.path.join(DEV, name), 0o660 | stat.S_IFCHR, os.makedev(81, minor))
        link('video4linux', name, node)
    if a.mic:
        num = next_minor('card')
        card = os.path.join(dev, f'{a.port}:1.2', 'sound', f'card{num}')
        w(os.path.join(card, 'id'), 'FAKEMIC')
        w(os.path.join(os.path.dirname(os.path.dirname(card)), 'bInterfaceClass'), '01')
        pcm = os.path.join(card, f'pcmC{num}D0c')
        os.makedirs(pcm)
        os.mknod(os.path.join(SND, f'pcmC{num}D0c'), 0o660 | stat.S_IFCHR, os.makedev(116, num))
        link('sound', f'card{num}', card)
        link('sound', f'pcmC{num}D0c', pcm)
    bus = os.path.join(SYS, 'bus', 'usb', 'devices')
    os.makedirs(bus, exist_ok=True)
    os.symlink(os.path.relpath(dev, bus), os.path.join(bus, a.port))
    print(f'branché {a.port}')


def unplug(port):
    dev = os.path.join(SYS, 'devices', 'usb9', port)
    if not os.path.isdir(dev):
        return
    # Ordre du noyau : les liens de classe et les nœuds disparaissent, puis l'appareil.
    for cls in ('video4linux', 'sound'):
        d = os.path.join(SYS, 'class', cls)
        for name in (os.listdir(d) if os.path.isdir(d) else []):
            if os.path.realpath(os.path.join(d, name)).startswith(dev + '/'):
                os.unlink(os.path.join(d, name))
                for nodes in (DEV, SND):
                    if os.path.lexists(os.path.join(nodes, name)):
                        os.unlink(os.path.join(nodes, name))
    os.unlink(os.path.join(SYS, 'bus', 'usb', 'devices', port))
    shutil.rmtree(dev)
    print(f'débranché {port}')


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    pl = sub.add_parser('plug')
    pl.add_argument('port')
    pl.add_argument('--vid', default='1b3f')
    pl.add_argument('--pid', default='0001')
    pl.add_argument('--product', default='Fausse webcam')
    pl.add_argument('--serial')
    pl.add_argument('--mic', action='store_true')
    un = sub.add_parser('unplug')
    un.add_argument('port')
    sub.add_parser('unplug-all')
    sub.add_parser('ls')
    a = p.parse_args()
    for d in (SYS, DEV, SND):
        os.makedirs(d, exist_ok=True)
    if a.cmd == 'plug':
        plug(a)
    elif a.cmd == 'unplug':
        unplug(a.port)
    elif a.cmd == 'unplug-all':
        base = os.path.join(SYS, 'devices', 'usb9')
        for port in (sorted(os.listdir(base)) if os.path.isdir(base) else []):
            unplug(port)
    else:
        base = os.path.join(SYS, 'devices', 'usb9')
        print(' '.join(sorted(os.listdir(base))) if os.path.isdir(base) else '')


if __name__ == '__main__':
    main()
