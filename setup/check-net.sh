#!/bin/bash
# Run on the receiver after setup finishes: checks each sender over the experiment LAN,
# at full MTU with DF set (catches switches that drop jumbo frames).
. /local/hostcc.env
echo "receiver $EXP_IP on $EXP_IF: $(ethtool "$EXP_IF" 2>/dev/null | sed -n 's/^\s*Speed: //p'), mtu $(cat /sys/class/net/$EXP_IF/mtu)"
rc=0
for ip in $SENDER_IPS; do
    small=$(ping -c 3 -W 1 -q "$ip" >/dev/null 2>&1 && echo ok || echo FAIL)
    big=$(ping -c 3 -W 1 -q -M "do" -s $((MTU - 28)) "$ip" >/dev/null 2>&1 && echo ok || echo FAIL)
    remote=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ip" \
        '. /local/hostcc.env; echo "$EXP_IF $(ethtool $EXP_IF 2>/dev/null | sed -n "s/^\s*Speed: //p") mtu=$(cat /sys/class/net/$EXP_IF/mtu); $(tail -1 /local/logs/setup.log)"' 2>/dev/null \
        || echo "ssh failed")
    echo "$ip: ping=$small ping(mtu $MTU, DF)=$big | $remote"
    [ "$small" = ok ] && [ "$big" = ok ] || rc=1
done
[ $rc -eq 0 ] && echo "network OK" || echo "network check FAILED (if only the MTU ping fails, rerun the profile with jumbo frames off)"
exit $rc
