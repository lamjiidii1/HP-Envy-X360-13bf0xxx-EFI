DefinitionBlock ("", "SSDT", 2, "CORP", "MICMUTE", 0x00001000)
{
    External (_SB_.PC00.LPCB.EC0_, DeviceObj)
    External (_SB_.PC00.LPCB.EC0_.XQ28, MethodObj)
    External (_SB_.PC00.LPCB.EC0_.MBMS, FieldUnitObj)
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)
    External (_SB_.WMID, DeviceObj)
    External (_SB_.WMID.STCS, MethodObj)

    Scope (\_SB.PC00.LPCB.EC0)
    {
        Method (_Q28, 0, NotSerialized)
        {
            If (CondRefOf (\_SB.PC00.LPCB.EC0.XQ28))
            {
                \_SB.PC00.LPCB.EC0.XQ28 ()
            }

            If (CondRefOf (\_SB.WMID.STCS))
            {
                If (\_SB.PC00.LPCB.EC0.MBMS == 0x01)
                {
                    \_SB.WMID.STCS (0x000000)
                }
                Else
                {
                    \_SB.WMID.STCS (0x000100)
                }
            }
            ElseIf (CondRefOf (\_SB.PC00.LPCB.EC0.MBMS))
            {
                If (\_SB.PC00.LPCB.EC0.MBMS == 0x01)
                {
                    \_SB.PC00.LPCB.EC0.MBMS = 0x00
                }
                Else
                {
                    \_SB.PC00.LPCB.EC0.MBMS = 0x01
                }
            }

            If (CondRefOf (\_SB.PC00.LPCB.PS2K))
            {
                Notify (\_SB.PC00.LPCB.PS2K, 0x036b)
            }
        }
    }
}
