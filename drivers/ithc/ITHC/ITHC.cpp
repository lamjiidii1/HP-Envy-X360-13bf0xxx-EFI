// ITHC: Intel Touch Host Controller driver for macOS (legacy THC mode).
// Port of the Linux ithc driver (https://github.com/quo/ithc-linux),
// used under its BSD-2-Clause license. See LICENSE.
#include "ITHC.hpp"
#include <IOKit/IOLib.h>
#include <IOKit/IOMessage.h>
#include <libkern/OSDebug.h>
#include <mach/kmod.h>
#include <pexpert/pexpert.h>

using namespace ITHCRegs;

OSDefineMetaClassAndStructors(ITHC,IOService)
OSDefineMetaClassAndStructors(ITHCHIDDevice,IOHIDDevice)

namespace {
// ithc-legacy.c: device config block read over SPI at offset 0.
constexpr uint32_t ConfigDeviceIdTIC=0x43495424; // "$TIC"
constexpr uint32_t ConfigTouchCfgOffset=0x0C;
constexpr uint32_t TouchEnable=1U<<0, TouchHidReportEnable=1U<<2, TouchMask=0x3F;
constexpr uint32_t TouchPowerState(uint32_t x) {return (x&7)<<3;}
// RX message codes (64-byte header: code, data size, 14 reserved words).
constexpr uint32_t RxInputReport=3, RxFeatureReport=4, RxReportDescriptor=5, RxReset=7;
constexpr uint32_t RxHeaderSize=64;
struct PRD {uint64_t addr;uint32_t size;uint32_t unused;}; // addr in 1 KiB units
static_assert(sizeof(PRD)==16,"PRD layout");
}

// Poll a register every 200 us for up to 1 s (ithc waitl/waitb).
bool ITHC::wait32(uint32_t o,uint32_t mask,uint32_t v) {
    for(unsigned i=0;i<5000;++i) {
        if((r32(o)&mask)==v)return true;
        IODelay(200);
    }
    return false;
}
bool ITHC::wait8(uint32_t o,uint8_t mask,uint8_t v) {
    for(unsigned i=0;i<5000;++i) {
        if((r8(o)&mask)==v)return true;
        IODelay(200);
    }
    return false;
}

bool ITHC::allocDMA(DMABuffer &b,uint32_t size) {
    b.size=uint32_t(round_page(size));
    b.md=IOBufferMemoryDescriptor::inTaskWithPhysicalMask(kernel_task,
        kIODirectionInOut|kIOMemoryPhysicallyContiguous,b.size,0xFFFFFFFFFFFFF000ULL);
    if(!b.md)return false;
    b.cmd=IODMACommand::withSpecification(kIODMACommandOutputHost64,64,0,IODMACommand::kMapped,0,PAGE_SIZE);
    if(!b.cmd || b.cmd->setMemoryDescriptor(b.md,true)!=kIOReturnSuccess)return false;
    IODMACommand::Segment64 segment {};
    UInt64 offset=0;UInt32 count=1;
    if(b.cmd->gen64IOVMSegments(&offset,&segment,&count)!=kIOReturnSuccess || count!=1 || segment.fLength<b.size)
        return false;
    b.dma=segment.fIOVMAddr;
    b.addr=static_cast<uint8_t *>(b.md->getBytesNoCopy());
    bzero(b.addr,b.size);
    return (b.dma&(PAGE_SIZE-1))==0;
}
void ITHC::freeDMA(DMABuffer &b) {
    if(b.cmd) {b.cmd->clearMemoryDescriptor(true);b.cmd->release();b.cmd=nullptr;}
    OSSafeReleaseNULL(b.md);
    b.addr=nullptr;b.dma=0;
}

void ITHC::setPowerD0() {
    uint8_t pm=0;
    if(!pci->findPCICapability(kIOPCIPowerManagementCapability,&pm) || !pm)return;
    const uint16_t pmcsr=pci->configRead16(pm+4);
    if(pmcsr&3) {pci->configWrite16(pm+4,pmcsr&~3U);IOSleep(10);}
}

// ithc_disable(): quiesce, hold the touch IC in reset, stop DMA and IRQs.
void ITHC::disableDevice() {
    bits32(ControlBits,ControlQuiesce,ControlQuiesce);
    wait32(ControlBits,ControlIsQuiesced,ControlIsQuiesced);
    bits32(ControlBits,ControlNReset,0);
    bits8(SpiCmdControl,SpiCmdSend,0);
    bits8(DmaTxControl,TxSend,0);
    for(unsigned c=0;c<2;++c)bits8(DmaRx(c)+RxControl,RxEnable,0);
    w32(ErrorControl,0);
    bits8(SpiCmdControl,SpiCmdIrq,0);
    for(unsigned c=0;c<2;++c)bits8(DmaRx(c)+RxControl,RxIrqUnknown1|RxIrqError|RxIrqReady|RxIrqData,0);
    bits8(DmaTxControl,TxIrq,0);
    w32(ErrorFlags,0xFFFFFFFF);
    w32(ErrorStatus,ErrorStatusDma|ErrorStatusSpi);
    w32(SpiCmdStatus,SpiStatusDone|SpiStatusError);
    for(unsigned c=0;c<2;++c)w32(DmaRx(c)+RxStatus,RxStatusError|RxStatusReady|RxStatusHaveData);
    w32(DmaTxStatus,TxStatusDone|TxStatusError|TxStatusUnknown2);
}

void ITHC::setSpiConfig(uint8_t clkdiv,bool clkdiv8,uint8_t readMode,uint8_t writeMode) {
    if(!clkdiv || clkdiv>7 || readMode>2 || writeMode>2)return;
    const uint32_t mask=(3U<<2)|(7U<<4)|(3U<<18)|(7U<<20)|(1U<<23);
    bits32(SpiConfig,mask,(uint32_t(readMode)<<2)|(uint32_t(clkdiv)<<4)|(uint32_t(writeMode)<<18)|
        (uint32_t(clkdiv)<<20)|(clkdiv8 ? 1U<<23 : 0));
}

// ithc_spi_command(): read/write the touch IC's config space (max 64 bytes).
bool ITHC::spiCommand(uint8_t code,uint32_t offset,uint32_t size,void *data) {
    if(size>64)return false;
    if(!wait32(SpiCmdStatus,SpiStatusBusy,0))return false;
    w32(SpiCmdStatus,SpiStatusDone|SpiStatusError);
    w8(SpiCmdCode,code);
    w16(SpiCmdSize,uint16_t(size));
    w32(SpiCmdOffset,offset);
    auto p=static_cast<uint32_t *>(data);const uint32_t n=(size+3)/4;
    for(uint32_t i=0;i<n;++i)w32(SpiCmdData+4*i,p[i]);
    bits8(SpiCmdControl,SpiCmdSend,SpiCmdSend);
    if(!wait32(SpiCmdStatus,SpiStatusBusy,0))return false;
    if((r32(SpiCmdStatus)&(SpiStatusDone|SpiStatusError))!=SpiStatusDone)return false;
    if(r16(SpiCmdSize)!=size)return false;
    for(uint32_t i=0;i<n;++i)p[i]=r32(SpiCmdData+4*i);
    w32(SpiCmdStatus,SpiStatusDone|SpiStatusError);
    return true;
}

void ITHC::setLtrConfig(uint64_t activeNs,uint64_t idleNs) {
    auto calc=[](uint64_t ns,uint32_t &val,uint32_t &scale) {
        uint32_t s=0;
        while(ns>0x3FF) {++s;ns>>=5;}
        if(s>5) {s=5;ns=0x3FF;}
        val=uint32_t(ns);scale=s;
    };
    uint32_t av,as,iv,is;calc(activeNs,av,as);calc(idleNs,iv,is);
    w32(LtrConfig,LtrEnableActive|LtrEnableIdle|LtrApply|((as&7)<<17)|((av&0x3FF)<<20)|((is&7)<<4)|((iv&0x3FF)<<7));
}
// The THC switches LTR to active at each DMA transfer but never back.
void ITHC::setLtrIdle() {
    const uint32_t ltr=r32(LtrConfig);
    if((ltr&(LtrStatusActive|LtrStatusIdle))==LtrStatusActive)w32(LtrConfig,ltr|LtrToggle|LtrApply);
}

bool ITHC::setDeviceEnabled(bool enable) {
    uint32_t x=touchCfg=(touchCfg&~TouchMask)|TouchHidReportEnable|(enable ? TouchEnable|TouchPowerState(3) : 0);
    return spiCommand(SpiCodeWrite,ConfigTouchCfgOffset,sizeof(x),&x);
}

// ithc_legacy_init(): take the touch IC out of reset and read its config.
bool ITHC::legacyInit() {
    setSpiConfig(2,true,0,0);
    bits32(DmaRx(0)+RxInitUnknown,InitUnknown31,InitUnknown31);
    bits32(DmaRx(0)+RxInitUnknown,InitUnknown5,InitUnknown5); // needed on ADL
    bits32(ControlBits,ControlQuiesce,0);
    if(!wait32(ControlBits,ControlIsQuiesced,0)) {failStep=10;return false;}
    for(unsigned retries=0;;++retries) {
        bits32(ControlBits,ControlNReset,ControlNReset);
        if(wait32(IrqCause,0xF,2))break;
        if(retries>5) {failStep=11;lastError=r32(IrqCause);return false;}
        bits32(ControlBits,ControlNReset,0);
        IOSleep(1000);
    }
    wait32(DmaRx(0)+RxStatus,RxStatusReady,RxStatusReady);
    for(unsigned retries=0;;++retries) {
        bzero(config,sizeof(config));
        if(!spiCommand(SpiCodeRead,0,sizeof(config),config)) {failStep=12;return false;}
        if(config[5]==ConfigDeviceIdTIC)break;
        if(retries>10) {failStep=13;lastError=config[5];return false;}
        IOSleep(100);
    }
    const uint32_t sizes=config[2],spi=config[6];
    maxRx=((sizes&0x3FFF)+1)<<6;
    maxTx=(((sizes>>14)&0x3FF)+1)<<6;
    vendor=uint16_t(config[7]);product=uint16_t(config[7]>>16);
    touchCfg=config[3];
    setSpiConfig((spi>>1)&7,(spi&(1U<<4))!=0,spi&(1U<<7) ? 2 : spi&(1U<<6) ? 1 : 0,0);
    if(!setDeviceEnabled(true)) {failStep=14;return false;}
    return true;
}

// ithc_init_device(): shut down, set LTR (50 us active, 100 ms idle), legacy init.
bool ITHC::initDevice() {
    const bool wasEnabled=(r32(ControlBits)&ControlNReset)!=0;
    disableDevice();
    if(!wait32(ControlBits,ControlReady,ControlReady)) {failStep=2;return false;}
    if(wasEnabled)IOSleep(100);
    setLtrConfig(50*1000,100*1000*1000ULL);
    return legacyInit();
}

void ITHC::rxPut(unsigned idx) {
    auto prd=reinterpret_cast<PRD *>(rxPrds.addr)+idx*rxPages;
    // Each buffer is one contiguous DMA range, so a single PRD describes it.
    prd->addr=rxBufs[idx].dma>>10;
    prd->size=(rxPages*PAGE_SIZE)|PrdFlagEnd;
    prd->unused=0;
    __sync_synchronize();
}
uint32_t ITHC::rxGet(unsigned idx) {
    __sync_synchronize();
    auto prd=reinterpret_cast<const PRD *>(rxPrds.addr)+idx*rxPages;
    uint32_t total=0;
    for(uint32_t i=0;i<rxPages;++i) {
        const uint32_t s=prd[i].size;
        total+=s&PrdSizeMask;
        if(s&PrdFlagEnd)break;
    }
    return total<rxPages*PAGE_SIZE ? total : rxPages*PAGE_SIZE;
}

bool ITHC::rxInit() {
    rxPages=(maxRx+PAGE_SIZE-1)/PAGE_SIZE;
    if(!rxPages || rxPages>16 || !allocDMA(rxPrds,NumRx*rxPages*sizeof(PRD)))return false;
    for(auto &b:rxBufs)if(!allocDMA(b,rxPages*PAGE_SIZE))return false;
    const uint32_t base=DmaRx(RxChannel);
    w8(base+RxControl2,RxControl2Reset);
    w64(base+RxAddr,rxPrds.dma);
    w8(base+RxNumBufs,NumRx-1);
    w8(base+RxNumPrds,uint8_t(rxPages-1));
    const uint8_t head=r8(base+RxHead);
    if(head) {failStep=20;lastError=head;return false;}
    for(unsigned i=0;i<NumRx;++i)rxPut(i);
    w8(base+RxTail,head^RxWrapFlag);
    numReceived=0;
    return true;
}
void ITHC::rxEnable() {
    const uint32_t base=DmaRx(RxChannel);
    bits8(base+RxControl,RxEnable|RxIrqError|RxIrqData,RxEnable|RxIrqError|RxIrqData);
    wait32(base+RxStatus,RxStatusEnabled,RxStatusEnabled);
}

bool ITHC::txInit() {
    if(maxTx>PAGE_SIZE)return false; // ithc: multi-page TX is not needed by any device
    if(!allocDMA(txPrds,sizeof(PRD)) || !allocDMA(txBuf,PAGE_SIZE))return false;
    w64(DmaTxAddr,txPrds.dma);
    w8(DmaTxNumPrds,0);
    auto prd=reinterpret_cast<PRD *>(txPrds.addr);
    prd->addr=txBuf.dma>>10;prd->size=PrdFlagEnd;prd->unused=0;
    return true;
}
// One TX message: header (code, size) then data padded to 4 bytes.
IOReturn ITHC::txLocked(uint32_t code,const void *data,uint32_t size) {
    const uint32_t padded=(size+3)&~3U;
    if(8+padded>maxTx)return kIOReturnOverrun;
    auto hdr=reinterpret_cast<uint32_t *>(txBuf.addr);
    hdr[0]=code;hdr[1]=size;
    bzero(txBuf.addr+8,padded);
    if(size)memcpy(txBuf.addr+8,data,size);
    auto prd=reinterpret_cast<PRD *>(txPrds.addr);
    prd->addr=txBuf.dma>>10;prd->size=(8+padded)|PrdFlagEnd;
    __sync_synchronize();
    bits8(DmaTxControl,TxSend,TxSend);
    if(!wait8(DmaTxControl,TxSend,0))return kIOReturnTimeout;
    w32(DmaTxStatus,TxStatusDone);
    return kIOReturnSuccess;
}
IOReturn ITHC::sendData(Tx type,const void *data,uint32_t size) {
    if(stopping || !regs)return kIOReturnNotReady;
    static const uint64_t descriptorRequest=0;
    if(type==Tx::GetReportDescriptor) {data=&descriptorRequest;size=sizeof(descriptorRequest);}
    IOLockLock(txLock);
    const auto r=txLocked(uint32_t(type),data,size);
    IOLockUnlock(txLock);
    return r;
}

// Get-feature replies arrive as RX messages on the work loop, so this
// must never be called from it.
IOReturn ITHC::getFeature(uint8_t reportID,void *buffer,uint32_t &size) {
    if(workLoop && workLoop->onThread())return kIOReturnNotPermitted;
    IOLockLock(waitLock);
    featureBuf=static_cast<uint8_t *>(buffer);featureSize=size;featurePending=true;
    IOLockUnlock(waitLock);
    IOReturn r=sendData(Tx::GetFeature,&reportID,1);
    IOLockLock(waitLock);
    if(r==kIOReturnSuccess) {
        AbsoluteTime deadline;clock_interval_to_deadline(1000,kMillisecondScale,&deadline);
        while(featurePending)
            if(IOLockSleepDeadline(waitLock,&featurePending,deadline,THREAD_UNINT)==THREAD_TIMED_OUT)break;
        r=featurePending ? kIOReturnTimeout : kIOReturnSuccess;
    }
    size=featureSize;featurePending=false;featureBuf=nullptr;
    IOLockUnlock(waitLock);
    return r;
}

void ITHC::handleRx(const uint8_t *data,uint32_t len) {
    if(len<RxHeaderSize) {++counts[7];return;}
    const uint32_t code=reinterpret_cast<const uint32_t *>(data)[0];
    const uint32_t size=reinterpret_cast<const uint32_t *>(data)[1];
    if(len!=RxHeaderSize+size) {++counts[7];return;} // RX data is not padded
    const uint8_t *payload=data+RxHeaderSize;
    switch(code) {
    case RxInputReport:
        ++counts[2];
        // Copy into the buffer directly: writeBytes() on a kIODirectionOut buffer
        // writes nothing, which delivered every report as zeros.
        if(hid && reportBuffer && size<=reportBuffer->getCapacity()) {
            memcpy(reportBuffer->getBytesNoCopy(),payload,size);
            reportBuffer->setLength(size);
            hid->handleReport(reportBuffer,kIOHIDReportTypeInput);
        }
        break;
    case RxReportDescriptor:
        ++counts[4];
        if(size<8)break; // preceded by 8 nul bytes
        IOLockLock(waitLock);
        if(!rdesc) {
            rdesc=static_cast<uint8_t *>(IOMalloc(size-8));
            if(rdesc) {memcpy(rdesc,payload+8,size-8);rdescSize=size-8;prepareDescriptor();}
        }
        rdescDone=true;
        IOLockWakeup(waitLock,&rdescDone,false);
        IOLockUnlock(waitLock);
        break;
    case RxFeatureReport:
        ++counts[3];
        IOLockLock(waitLock);
        if(featurePending && featureBuf) {
            if(size<featureSize)featureSize=size;
            memcpy(featureBuf,payload,featureSize);
            featurePending=false;
            IOLockWakeup(waitLock,&featurePending,false);
        }
        IOLockUnlock(waitLock);
        break;
    case RxReset:
        // The THC asks to be reinitialized (ithc_reset).
        ++counts[5];
        if(counts[5]<=8 && initDevice())rxEnable();
        break;
    default:
        ++counts[7];
        break;
    }
}

// ithc_dma_rx(): drain every filled buffer from the ring.
void ITHC::processRx() {
    const uint32_t base=DmaRx(RxChannel);
    uint32_t n=numReceived;
    const uint8_t headWrap=r8(base+RxHead);
    for(unsigned guard=0;guard<4*NumRx;++guard) {
        const uint8_t tail=uint8_t(n%NumRx);
        const uint8_t tailWrap=tail|(((n/NumRx)&1) ? 0 : RxWrapFlag);
        w8(base+RxTail,tailWrap);
        if(tailWrap==(headWrap^RxWrapFlag))return; // empty
        const uint32_t len=rxGet(tail);
        numReceived=++n;++counts[1];
        handleRx(rxBufs[tail].addr,len);
        rxPut(tail);
    }
}

void ITHC::process() {
    if(stopping)return;
    if(idleTimer)idleTimer->setTimeoutMS(1000);
    const uint32_t base=DmaRx(RxChannel);
    const bool rx=(r32(base+RxStatus)&(RxStatusError|RxStatusHaveData))!=0;
    const uint32_t err=r32(ErrorFlags);
    if(err) {w32(ErrorFlags,err);lastError=err;++counts[6];}
    w32(base+RxStatus,RxStatusError|RxStatusReady|RxStatusHaveData);
    if(rx)processRx();
}

void ITHC::interruptOccurred(IOInterruptEventSource *,int) {++counts[0];process();}
void ITHC::idleTimeout(IOTimerEventSource *) {if(!stopping) {setLtrIdle();publishState();}}
void ITHC::pollTimeout(IOTimerEventSource *timer) {
    if(stopping)return;
    const uint32_t before=numReceived;
    process();
    timer->setTimeoutMS(numReceived!=before ? 10 : 50);
}

// Walk the report descriptor once. Hide top-level keyboard collections from
// macOS (they made it run Keyboard Setup Assistant; their reports still parse),
// and note a one-byte Contact Count Maximum feature and its logical maximum.
void ITHC::prepareDescriptor() {
    uint32_t page=0,usage=0,usageOffset=0,depth=0,reportSize=0,reportCount=0;
    int32_t logicalMax=0;uint8_t reportID=0;
    for(uint32_t i=0;i<rdescSize;) {
        const uint8_t b=rdesc[i];
        if(b==0xFE) { // long item
            if(i+1>=rdescSize)break;
            i+=3+rdesc[i+1];continue;
        }
        const uint32_t n=(b&3)==3 ? 4 : (b&3);
        if(i+1+n>rdescSize)break;
        uint32_t v=0;for(uint32_t k=0;k<n;++k)v|=uint32_t(rdesc[i+1+k])<<(8*k);
        switch(b&0xFC) {
        case 0x04:page=v;break;                         // Usage Page
        case 0x08:usage=v;usageOffset=i;break;          // Usage
        case 0x84:reportID=uint8_t(v);break;            // Report ID
        case 0x74:reportSize=v;break;                   // Report Size
        case 0x94:reportCount=v;break;                  // Report Count
        case 0x24:logicalMax=n==1 ? int8_t(v) : n==2 ? int16_t(v) : int32_t(v);break;
        case 0xA0:                                      // Collection
            if(!depth && page==0x01 && (usage==0x06 || usage==0x07) && (rdesc[usageOffset]&0xFC)==0x08 &&
               (rdesc[usageOffset]&3)==1)
                rdesc[usageOffset+1]=0; // Generic Desktop Keyboard/Keypad -> Undefined
            ++depth;break;
        case 0xC0:if(depth)--depth;break;              // End Collection
        case 0xB0:                                      // Feature
            if(page==0x0D && usage==0x55 && reportID && reportSize==8 && reportCount==1 && logicalMax>0 && logicalMax<256) {
                contactMaxReport=reportID;contactMaxValue=uint8_t(logicalMax);
            }
            break;
        }
        if((b&0x0C)==0x00)usage=(b&0xFC)==0xA0 || (b&0xFC)==0xC0 ? usage : 0; // locals reset after main items
        i+=1+n;
    }
}

bool ITHC::readDescriptor() {
    for(unsigned retries=0;retries<6;++retries) {
        IOLockLock(waitLock);rdescDone=false;IOLockUnlock(waitLock);
        if(sendData(Tx::GetReportDescriptor,nullptr,0)!=kIOReturnSuccess)continue;
        IOLockLock(waitLock);
        AbsoluteTime deadline;clock_interval_to_deadline(200,kMillisecondScale,&deadline);
        while(!rdescDone)
            if(IOLockSleepDeadline(waitLock,&rdescDone,deadline,THREAD_UNINT)==THREAD_TIMED_OUT)break;
        const bool done=rdescDone && rdesc;
        IOLockUnlock(waitLock);
        if(done)return true;
    }
    return false;
}

void ITHC::publishState() {
    // config[16], counts[8] (irq, rx, input, feature, descriptor, reset, errors, bad),
    // then lastError, failStep, maxRx, maxTx, vendor<<16|product, numReceived, polling, rdescSize.
    // Then contactMaxReport<<8|contactMaxValue.
    uint64_t r[16+8+8+1] {};
    for(unsigned i=0;i<16;++i)r[i]=config[i];
    for(unsigned i=0;i<8;++i)r[16+i]=counts[i];
    r[24]=lastError;r[25]=failStep;r[26]=maxRx;r[27]=maxTx;
    r[28]=(uint32_t(vendor)<<16)|product;r[29]=numReceived;r[30]=polling;r[31]=rdescSize;
    r[32]=(uint32_t(contactMaxReport)<<8)|contactMaxValue;
    setProperty("ITHCState",r,sizeof(r));
}

bool ITHC::start(IOService *provider) {
    int off=0;
    if(PE_parse_boot_argn("-ithcoff",&off,sizeof(off))) {
        IOLog("ITHC: disabled via -ithcoff boot argument\n");
        return false;
    }
    if(!super::start(provider))return false;
    pci=OSDynamicCast(IOPCIDevice,provider);
    if(!pci)return false;
    pci->retain();
    if(!pci->open(this)) {failStep=1;publishState();return false;}
    setPowerD0();
    pci->setMemoryEnable(true);
    pci->setBusMasterEnable(true);
    map=pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    if(!map || map->getLength()<0x1300) {failStep=3;goto fail;}
    regs=reinterpret_cast<volatile uint8_t *>(map->getVirtualAddress());
    txLock=IOLockAlloc();waitLock=IOLockAlloc();
    workLoop=IOWorkLoop::workLoop();
    if(!txLock || !waitLock || !workLoop) {failStep=4;goto fail;}
    {
        int msi=-1;
        for(int i=0;;++i) {
            int type=0;
            if(pci->getInterruptType(i,&type)!=kIOReturnSuccess)break;
            if(type&kIOInterruptTypePCIMessaged) {msi=i;break;}
        }
        int flag=0;
        polling=msi<0 || PE_parse_boot_argn("-ithcpoll",&flag,sizeof(flag));
        idleTimer=IOTimerEventSource::timerEventSource(this,OSMemberFunctionCast(IOTimerEventSource::Action,this,&ITHC::idleTimeout));
        if(!idleTimer || workLoop->addEventSource(idleTimer)!=kIOReturnSuccess) {failStep=5;goto fail;}
        if(!initDevice())goto fail;
        if(!rxInit()) {if(!failStep)failStep=21;goto fail;}
        if(!txInit()) {failStep=22;goto fail;}
        reportBuffer=IOBufferMemoryDescriptor::withCapacity(maxRx,kIODirectionOut);
        if(!reportBuffer) {failStep=23;goto fail;}
        if(polling) {
            pollTimer=IOTimerEventSource::timerEventSource(this,OSMemberFunctionCast(IOTimerEventSource::Action,this,&ITHC::pollTimeout));
            if(!pollTimer || workLoop->addEventSource(pollTimer)!=kIOReturnSuccess) {failStep=24;goto fail;}
            pollTimer->setTimeoutMS(50);
        } else {
            interrupt=IOInterruptEventSource::interruptEventSource(this,
                OSMemberFunctionCast(IOInterruptEventSource::Action,this,&ITHC::interruptOccurred),pci,msi);
            if(!interrupt || workLoop->addEventSource(interrupt)!=kIOReturnSuccess) {failStep=25;goto fail;}
            interrupt->enable();
        }
        rxEnable();
        if(!readDescriptor()) {failStep=30;goto fail;}
        // The touchscreen's own HID device, which VoodooI2CHID's event drivers match.
        hid=OSTypeAlloc(ITHCHIDDevice);
        if(!hid || !hid->init(this) || !hid->attach(this)) {failStep=31;OSSafeReleaseNULL(hid);goto fail;}
        if(!hid->start(this)) {failStep=32;hid->detach(this);OSSafeReleaseNULL(hid);goto fail;}
        setLtrIdle();
    }
    publishState();
    registerService();
    return true;
fail:
    publishState();
    stopping=true;
    if(pollTimer)pollTimer->cancelTimeout();
    if(interrupt)interrupt->disable();
    if(regs)disableDevice();
    if(pci)pci->close(this);
    return false;
}

void ITHC::stop(IOService *provider) {
    stopping=true;
    if(pollTimer)pollTimer->cancelTimeout();
    if(idleTimer)idleTimer->cancelTimeout();
    if(interrupt)interrupt->disable();
    if(regs) {
        setDeviceEnabled(false);
        disableDevice();
        for(unsigned c=0;c<2;++c) {
            wait32(DmaRx(c)+RxStatus,RxStatusEnabled,0);
            w64(DmaRx(c)+RxAddr,0);w8(DmaRx(c)+RxNumBufs,0);w8(DmaRx(c)+RxNumPrds,0);
        }
        w64(DmaTxAddr,0);w8(DmaTxNumPrds,0);
    }
    if(hid) {hid->terminate(kIOServiceSynchronous);OSSafeReleaseNULL(hid);}
    if(pci)pci->close(this);
    super::stop(provider);
}

void ITHC::free() {
    if(workLoop) {
        if(interrupt)workLoop->removeEventSource(interrupt);
        if(idleTimer)workLoop->removeEventSource(idleTimer);
        if(pollTimer)workLoop->removeEventSource(pollTimer);
    }
    OSSafeReleaseNULL(interrupt);OSSafeReleaseNULL(idleTimer);OSSafeReleaseNULL(pollTimer);
    OSSafeReleaseNULL(workLoop);
    OSSafeReleaseNULL(hid);
    freeDMA(rxPrds);for(auto &b:rxBufs)freeDMA(b);freeDMA(txPrds);freeDMA(txBuf);
    OSSafeReleaseNULL(reportBuffer);
    if(rdesc) {IOFree(rdesc,rdescSize);rdesc=nullptr;}
    OSSafeReleaseNULL(map);
    if(txLock) {IOLockFree(txLock);txLock=nullptr;}
    if(waitLock) {IOLockFree(waitLock);waitLock=nullptr;}
    OSSafeReleaseNULL(pci);
    super::free();
}

// HID device published on top of the THC.

bool ITHCHIDDevice::init(ITHC *owner) {
    if(!super::init(nullptr))return false;
    thc=owner;
    return true;
}
IOReturn ITHCHIDDevice::newReportDescriptor(IOMemoryDescriptor **descriptor) const {
    uint32_t size=0;auto data=thc ? thc->reportDescriptor(size) : nullptr;
    if(!data || !size)return kIOReturnNotReady;
    auto md=IOBufferMemoryDescriptor::withBytes(data,size,kIODirectionNone);
    if(!md)return kIOReturnNoMemory;
    *descriptor=md;
    return kIOReturnSuccess;
}
OSString *ITHCHIDDevice::newTransportString() const {return OSString::withCString("SPI");}
OSString *ITHCHIDDevice::newManufacturerString() const {return OSString::withCString("Intel");}
OSString *ITHCHIDDevice::newProductString() const {return OSString::withCString("THC Touchscreen");}
OSNumber *ITHCHIDDevice::newVendorIDNumber() const {return OSNumber::withNumber(thc ? thc->vendorID() : 0,32);}
OSNumber *ITHCHIDDevice::newProductIDNumber() const {return OSNumber::withNumber(thc ? thc->productID() : 0,32);}
OSNumber *ITHCHIDDevice::newLocationIDNumber() const {return OSNumber::withNumber(0x00100006ULL,32);}

// The THC protocol carries the report ID as the first data byte.
IOReturn ITHCHIDDevice::setReport(IOMemoryDescriptor *report,IOHIDReportType reportType,IOOptionBits options) {
    if(!thc || !report)return kIOReturnBadArgument;
    const uint8_t id=uint8_t(options&0xFF);
    const auto len=uint32_t(min(report->getLength(),IOByteCount(4096)));
    auto buf=static_cast<uint8_t *>(IOMalloc(len+1));if(!buf)return kIOReturnNoMemory;
    report->readBytes(0,buf+1,len);
    uint8_t *data=buf+1;uint32_t size=len;
    if(id && (!len || buf[1]!=id)) {buf[0]=id;data=buf;size=len+1;}
    IOReturn r=kIOReturnUnsupported;
    if(reportType==kIOHIDReportTypeFeature)r=thc->sendData(ITHC::Tx::SetFeature,data,size);
    else if(reportType==kIOHIDReportTypeOutput)r=thc->sendData(ITHC::Tx::OutputReport,data,size);
    IOFree(buf,len+1);
    return r;
}
IOReturn ITHCHIDDevice::getReport(IOMemoryDescriptor *report,IOHIDReportType reportType,IOOptionBits options) {
    if(!thc || !report)return kIOReturnBadArgument;
    const uint8_t id=uint8_t(options&0xFF);
    // IOHIDDevice passes a buffer sized for its largest report (7488 bytes on
    // the ELAN panel); a THC message is at most one RX buffer.
    const auto len=uint32_t(min(report->getLength(),IOByteCount(4160)));
    if(!len)return kIOReturnBadArgument;
    auto buf=static_cast<uint8_t *>(IOMalloc(len));if(!buf)return kIOReturnNoMemory;
    uint32_t size=len;IOReturn r=kIOReturnUnsupported;
    if(reportType==kIOHIDReportTypeFeature) {
        r=thc->getFeature(id,buf,size);
        if(r!=kIOReturnSuccess && id && id==thc->contactMaxReport && len>=2) {
            // VoodooI2C sizes its finger slots from Contact Count Maximum.
            buf[0]=id;buf[1]=thc->contactMaxValue;size=2;r=kIOReturnSuccess;
        }
    }
    if(r==kIOReturnSuccess) {
        report->writeBytes(0,buf,size);
        if(auto b=OSDynamicCast(IOBufferMemoryDescriptor,report))b->setLength(size);
    }
    IOFree(buf,len);
    return r;
}

extern "C" kern_return_t ithcStart(kmod_info_t *,void *) {return KERN_SUCCESS;}
extern "C" kern_return_t ithcStop(kmod_info_t *,void *) {return KERN_SUCCESS;}
KMOD_EXPLICIT_DECL(com.retropineaple.ITHC,"0.1.0",ithcStart,ithcStop)
__attribute__((visibility("hidden"))) kmod_start_func_t *_realmain=ithcStart;
__attribute__((visibility("hidden"))) kmod_stop_func_t *_antimain=ithcStop;
