#!/usr/bin/env python3
"""Build ITHC.kext (Intel Touch Host Controller) with MacKernelSDK, no Xcode project."""
import argparse,hashlib,plistlib,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
NAME='ITHC'
VERSION='0.1.0'
IDENT='com.retropineaple.ITHC'
# ADL-P THC ports (the HP Envy x360 13-bf touchscreen is on port 1).
PCI_MATCH='0x51d08086 0x51d18086'
def run(cmd): subprocess.run([str(x) for x in cmd],check=True,cwd=ROOT)
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--sdk',type=Path,default=ROOT/'MacKernelSDK')
 p.add_argument('--output',type=Path,default=ROOT/'build')
 a=p.parse_args();out=a.output.resolve();sdk=a.sdk.resolve()
 bundle=out/(NAME+'.kext')/'Contents';(bundle/'MacOS').mkdir(parents=True,exist_ok=True)
 objdir=out/'obj';objdir.mkdir(parents=True,exist_ok=True)
 base=['xcrun','clang++','-arch','x86_64','-std=c++17','-O2','-g','-mkernel','-fapple-kext','-fno-exceptions','-fno-rtti',
       '-fno-stack-protector','-fno-builtin','-fno-asynchronous-unwind-tables','-mno-red-zone','-nostdinc','-DKERNEL',
       '-DKERNEL_PRIVATE','-D__APPLE__','-D__MACH__','-D_FORTIFY_SOURCE=0','-I'+str(sdk/'Headers'),'-I'+str(ROOT/NAME),'-mmacosx-version-min=10.15',
       '-Wall','-Wextra','-Wno-unused-parameter','-Wno-deprecated-declarations','-Wno-ossharedptr-misuse',
       '-fdebug-compilation-dir=.','-ffile-prefix-map='+str(ROOT)+'=/ITHC','-ffile-prefix-map='+str(sdk)+'=/MacKernelSDK']
 objects=[]
 for source in sorted((ROOT/NAME).glob('*.cpp')):
  obj=objdir/(source.stem+'.o');run(base+['-c',source,'-o',obj]);objects.append(obj)
 exe=bundle/'MacOS'/NAME
 run(['xcrun','ld','-arch','x86_64','-kext','-undefined','dynamic_lookup','-no_fixup_chains','-macos_version_min','10.15',
      '-o',exe,*objects,sdk/'Library/x86_64/libkmod.a'])
 libs={'com.apple.kpi.iokit':'14.0','com.apple.kpi.libkern':'14.0','com.apple.kpi.mach':'14.0','com.apple.kpi.unsupported':'14.0',
       'com.apple.iokit.IOPCIFamily':'2.9','com.apple.iokit.IOHIDFamily':'2.0'}
 info=dict(CFBundleIdentifier=IDENT,CFBundleExecutable=NAME,CFBundleName=NAME,CFBundlePackageType='KEXT',
           CFBundleInfoDictionaryVersion='6.0',CFBundleVersion=VERSION,CFBundleShortVersionString=VERSION,
           OSBundleCompatibleVersion=VERSION,OSBundleRequired='Root',OSBundleLibraries=libs,
           IOKitPersonalities={NAME:dict(CFBundleIdentifier=IDENT,IOClass=NAME,IOProviderClass='IOPCIDevice',
                                          IOPCIMatch=PCI_MATCH,IOProbeScore=1000)})
 (bundle/'Info.plist').write_bytes(plistlib.dumps(info))
 run(['xcrun','strip','-S',exe])
 symbols=subprocess.check_output(['xcrun','nm',str(exe)],text=True)
 assert ' _kmod_info' in symbols and ' __realmain' in symbols, 'missing kext lifecycle metadata'
 unresolved=subprocess.check_output(['xcrun','nm','-u',str(exe)],text=True)
 assert '__ZN4ITHC' not in unresolved and '__ZN13ITHCHIDDevice' not in unresolved, 'unresolved local implementation'
 assert not any(x in unresolved for x in ['chkstk_darwin','___memcpy_chk']), 'userspace ABI imported'
 print(NAME,VERSION,hashlib.sha256(exe.read_bytes()).hexdigest())
if __name__=='__main__':main()
