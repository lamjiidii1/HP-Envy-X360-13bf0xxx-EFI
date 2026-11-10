// ITHC: Intel Touch Host Controller driver for macOS (legacy THC mode).
// Port of the Linux ithc driver (https://github.com/quo/ithc-linux),
// used under its BSD-2-Clause license. See LICENSE.
#ifndef ITHC_HPP
#define ITHC_HPP
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOInterruptEventSource.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODMACommand.h>
#include <IOKit/IOLocks.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/hid/IOHIDDevice.h>

namespace ITHCRegs {
// ithc-regs.h, struct ithc_registers.
constexpr uint32_t LtrConfig=0x0014, ControlBits=0x1008, SpiConfig=0x1010;
constexpr uint32_t ErrorControl=0x1020, ErrorStatus=0x1024, ErrorFlags=0x1028;
constexpr uint32_t SpiCmdControl=0x1040, SpiCmdCode=0x1041, SpiCmdSize=0x1042, SpiCmdStatus=0x1044;
constexpr uint32_t SpiCmdOffset=0x1048, SpiCmdData=0x104C;
constexpr uint32_t DmaTxAddr=0x1090, DmaTxControl=0x1098, DmaTxNumPrds=0x109B, DmaTxStatus=0x109C;
constexpr uint32_t IrqCause=0x10BC;
constexpr uint32_t DmaRx(unsigned c) {return 0x1100+0x100*c;}
constexpr uint32_t RxAddr=0x00, RxNumBufs=0x08, RxNumPrds=0x09, RxControl=0x0C, RxHead=0x0D, RxTail=0x0E;
constexpr uint32_t RxControl2=0x0F, RxStatus=0x10, RxInitUnknown=0x28;

constexpr uint32_t LtrEnableActive=1U<<0, LtrToggle=1U<<1, LtrEnableIdle=1U<<2, LtrApply=1U<<3;
constexpr uint32_t LtrStatusActive=1U<<30, LtrStatusIdle=1U<<31;
constexpr uint32_t ControlQuiesce=1U<<1, ControlIsQuiesced=1U<<2, ControlNReset=1U<<3, ControlReady=1U<<29;
constexpr uint32_t ErrorStatusDma=1U<<28, ErrorStatusSpi=1U<<30, ErrorFlagDmaRxTimeout=1U<<12;
constexpr uint8_t SpiCmdSend=1U<<0, SpiCmdIrq=1U<<1;
constexpr uint8_t SpiCodeRead=4, SpiCodeWrite=6;
constexpr uint32_t SpiStatusDone=1U<<0, SpiStatusError=1U<<1, SpiStatusBusy=1U<<3;
constexpr uint8_t TxSend=1U<<0, TxIrq=1U<<3;
constexpr uint32_t TxStatusDone=1U<<0, TxStatusError=1U<<1, TxStatusUnknown2=1U<<2;
constexpr uint8_t RxEnable=1U<<0, RxIrqUnknown1=1U<<1, RxIrqError=1U<<3, RxIrqReady=1U<<4, RxIrqData=1U<<5;
constexpr uint8_t RxControl2Reset=1U<<7, RxWrapFlag=1U<<7;
constexpr uint32_t RxStatusError=1U<<3, RxStatusReady=1U<<4, RxStatusHaveData=1U<<5, RxStatusEnabled=1U<<8;
constexpr uint32_t InitUnknown5=1U<<5, InitUnknown31=1U<<31;
constexpr uint32_t PrdSizeMask=0xFFFFFF, PrdFlagEnd=0x1000000;
}

class ITHCHIDDevice;

class ITHC : public IOService {
    OSDeclareDefaultStructors(ITHC)
    using super=IOService;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // For ITHCHIDDevice.
    enum class Tx : uint32_t {SetFeature=3, GetFeature=4, OutputReport=5, GetReportDescriptor=7};
    IOReturn sendData(Tx type,const void *data,uint32_t size);
    IOReturn getFeature(uint8_t reportID,void *buffer,uint32_t &size);
    const uint8_t *reportDescriptor(uint32_t &size) const {size=rdescSize;return rdesc;}
    uint16_t vendorID() const {return vendor;}
    uint16_t productID() const {return product;}
    // Descriptor-derived answer for a Contact Count Maximum feature the device
    // does not answer: report ID and the field's logical maximum.
    uint8_t contactMaxReport {}, contactMaxValue {};

private:
    struct DMABuffer {
        IOBufferMemoryDescriptor *md {};
        IODMACommand *cmd {};
        uint64_t dma {};
        uint8_t *addr {};
        uint32_t size {};
    };
    static constexpr unsigned NumRx=16, RxChannel=1;

    IOPCIDevice *pci {};
    IOMemoryMap *map {};
    volatile uint8_t *regs {};
    IOWorkLoop *workLoop {};
    IOInterruptEventSource *interrupt {};
    IOTimerEventSource *idleTimer {}, *pollTimer {};
    IOLock *txLock {}, *waitLock {};
    DMABuffer rxPrds, rxBufs[NumRx], txPrds, txBuf;
    IOBufferMemoryDescriptor *reportBuffer {};
    ITHCHIDDevice *hid {};

    uint32_t maxRx {}, maxTx {}, rxPages {}, numReceived {}, touchCfg {};
    uint16_t vendor {}, product {};
    uint32_t config[16] {};
    uint8_t *rdesc {};
    uint32_t rdescSize {};
    void prepareDescriptor();
    bool rdescDone {}, featurePending {}, stopping {}, polling {};
    uint8_t *featureBuf {};
    uint32_t featureSize {};
    uint64_t counts[8] {}; // interrupts, rx, input, feature, descriptor, reset, errors, bad
    uint32_t lastError {}, failStep {};

    uint32_t r32(uint32_t o) const {return *reinterpret_cast<volatile uint32_t *>(regs+o);}
    uint16_t r16(uint32_t o) const {return *reinterpret_cast<volatile uint16_t *>(regs+o);}
    uint8_t r8(uint32_t o) const {return regs[o];}
    void w32(uint32_t o,uint32_t v) {*reinterpret_cast<volatile uint32_t *>(regs+o)=v;}
    void w16(uint32_t o,uint16_t v) {*reinterpret_cast<volatile uint16_t *>(regs+o)=v;}
    void w8(uint32_t o,uint8_t v) {regs[o]=v;}
    void w64(uint32_t o,uint64_t v) {w32(o,uint32_t(v));w32(o+4,uint32_t(v>>32));} // lo_hi_writeq
    void bits32(uint32_t o,uint32_t mask,uint32_t v) {w32(o,(r32(o)&~mask)|(v&mask));}
    void bits8(uint32_t o,uint8_t mask,uint8_t v) {w8(o,uint8_t((r8(o)&~mask)|(v&mask)));}
    bool wait32(uint32_t o,uint32_t mask,uint32_t v);
    bool wait8(uint32_t o,uint8_t mask,uint8_t v);

    bool allocDMA(DMABuffer &b,uint32_t size);
    void freeDMA(DMABuffer &b);
    void setPowerD0();
    void disableDevice();
    bool initDevice();
    bool legacyInit();
    bool spiCommand(uint8_t code,uint32_t offset,uint32_t size,void *data);
    void setSpiConfig(uint8_t clkdiv,bool clkdiv8,uint8_t readMode,uint8_t writeMode);
    void setLtrConfig(uint64_t activeNs,uint64_t idleNs);
    void setLtrIdle();
    bool setDeviceEnabled(bool enable);
    bool rxInit();
    void rxPut(unsigned idx);
    uint32_t rxGet(unsigned idx);
    void rxEnable();
    bool txInit();
    IOReturn txLocked(uint32_t code,const void *data,uint32_t size);
    void process();
    void processRx();
    void handleRx(const uint8_t *data,uint32_t len);
    bool readDescriptor();
    void publishState();
    void interruptOccurred(IOInterruptEventSource *source,int count);
    void idleTimeout(IOTimerEventSource *timer);
    void pollTimeout(IOTimerEventSource *timer);
};

class ITHCHIDDevice : public IOHIDDevice {
    OSDeclareDefaultStructors(ITHCHIDDevice)
    using super=IOHIDDevice;
public:
    bool init(ITHC *owner);
    IOReturn newReportDescriptor(IOMemoryDescriptor **descriptor) const override;
    OSString *newTransportString() const override;
    OSString *newManufacturerString() const override;
    OSString *newProductString() const override;
    OSNumber *newVendorIDNumber() const override;
    OSNumber *newProductIDNumber() const override;
    OSNumber *newLocationIDNumber() const override;
    IOReturn setReport(IOMemoryDescriptor *report,IOHIDReportType reportType,IOOptionBits options) override;
    IOReturn getReport(IOMemoryDescriptor *report,IOHIDReportType reportType,IOOptionBits options) override;
private:
    ITHC *thc {};
};
#endif
