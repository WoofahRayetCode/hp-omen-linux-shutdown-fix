/*
 * Experimental SSDT: request dGPU rail off on S5 only.
 *
 * This is a template, not a universal AML blob. Paths differ by board/BIOS.
 * Verify with `sudo strings /sys/firmware/acpi/tables/DSDT | grep -E 'PG00|GPTS|PEGP'`
 * and iasl -d of your own DSDT before using.
 *
 * Preferred path on 16-ap0xxx: firmware PG00._OFF works; Linux never calls it at S5.
 * Load as a *second* bootloader entry. Keep the stock kernel entry.
 *
 * Compile: iasl -tc ssdt-omen-s5.asl
 * Then follow your distro's acpi_override / acpi initramfs docs.
 *
 * Do not flash BIOS. Do not replace the stock DSDT unless you know the table.
 */
DefinitionBlock ("ssdt-omen-s5.aml", "SSDT", 2, "OMENFX", "S5DGPU", 0x00000001)
{
    External (\_SB.PCI0.GPP0.PG00._OFF, MethodObj)
    External (\_SB.PCI0.GPP0.PEGP._PS3, MethodObj)

    Method (\_PTS, 1, NotSerialized)
    {
        If ((Arg0 == 0x05))
        {
            If (CondRefOf (\_SB.PCI0.GPP0.PEGP._PS3))
            {
                \_SB.PCI0.GPP0.PEGP._PS3 ()
            }
            If (CondRefOf (\_SB.PCI0.GPP0.PG00._OFF))
            {
                \_SB.PCI0.GPP0.PG00._OFF ()
            }
        }
    }
}
