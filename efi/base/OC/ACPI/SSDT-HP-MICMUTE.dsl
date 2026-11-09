DefinitionBlock ("", "SSDT", 2, "CORP", "MICMUTE", 0x00001000)
{
    External (_SB_.PC00.LPCB.EC0_, DeviceObj)
    External (_SB_.PC00.LPCB.EC0_.XQ28, MethodObj)
    External (_SB_.PC00.LPCB.EC0_.MBMS, FieldUnitObj)
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)

    Scope (\_SB.PC00.LPCB.EC0)
    {
        Method (_Q28, 0, NotSerialized)
        {
            If (CondRefOf (\_SB.PC00.LPCB.EC0.XQ28))
            {
                \_SB.PC00.LPCB.EC0.XQ28 ()
            }

            If (CondRefOf (\_SB.PC00.LPCB.EC0.MBMS))
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
                Notify (\_SB.PC00.LPCB.PS2K, 0x046b)
            }
        }
    }
}
