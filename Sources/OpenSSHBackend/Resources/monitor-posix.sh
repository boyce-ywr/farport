export LC_ALL=C
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
printf 'FARPORT_MONITOR_V1\n'
info() { printf 'info\t%s\t' "$1"; printf '%s' "$2" | tr '\t\r\n' '   '; printf '\n'; }
warning() { printf 'warning\t%s\n' "$1"; }
system=$(uname -s 2>/dev/null)
if [ "$1" = info ]; then
    info hostname "$(hostname 2>/dev/null)"
    info architecture "$(uname -m 2>/dev/null)"
    info kernel "$(uname -r 2>/dev/null)"
    info username "$(id -un 2>/dev/null)"
    info uid "$(id -u 2>/dev/null)"
    info groups "$(id -Gn 2>/dev/null)"
    info home "$HOME"
    loginShell="$SHELL"
    if [ -z "$loginShell" ] && [ -r /etc/passwd ]; then loginShell=$(awk -F: -v user="$(id -un)" '$1==user {print $7}' /etc/passwd); fi
    info shell "$loginShell"
fi
case "$system" in
Linux)
    if [ "$1" = info ]; then
        if [ -x /system/bin/getprop ]; then
            info os "Android $(/system/bin/getprop ro.build.version.release 2>/dev/null) / Termux ${TERMUX_VERSION:-unknown}"
            info model "$(/system/bin/getprop ro.product.manufacturer 2>/dev/null) $(/system/bin/getprop ro.product.model 2>/dev/null)"
        else
            info os "$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release 2>/dev/null)"
        fi
        info cpuModel "$(awk -F: '/model name|Hardware|Model/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
        info logicalCPUs "$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
        warning process-scope
        warning process-bandwidth-unavailable
    fi
    if [ -r /proc/uptime ]; then awk '{print "uptime\t" $1}' /proc/uptime 2>/dev/null; fi
    if [ -r /proc/stat ]; then
        awk '$1=="cpu" {for(i=2;i<=9;i++) total+=$i; printf "cpu\t%.0f\t%.0f\n",total,$5+$6; exit}' /proc/stat 2>/dev/null
    else warning cpu-unavailable; fi
    if [ -r /proc/meminfo ]; then
        awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2; found=1} END {if(total>0 && found) printf "memory\t%.0f\t%.0f\n",total*1024,(total-available)*1024; else print "warning\tmemory-unavailable"}' /proc/meminfo 2>/dev/null
    else warning memory-unavailable; fi
    ticks=$(getconf CLK_TCK 2>/dev/null)
    uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    if [ -n "$ticks" ] && [ -n "$uptime" ] && [ -r /proc/self/stat ]; then
        awk -v hz="$ticks" -v up="$uptime" '
        FILENAME ~ /\/stat$/ {
            pid=$1; line=$0; sub(/^[0-9]+ \(/,"",line); sub(/\) [A-Za-z].*$/,"",line); gsub(/[\t\r\n]/," ",line); names[pid]=line
            rest=$0; sub(/^.*\) /,"",rest); split(rest,fields," ")
            cpu[pid]=(fields[12]+fields[13])/hz; started[pid]=fields[20]; elapsed[pid]=up-fields[20]/hz
        }
        FILENAME ~ /\/status$/ {
            split(FILENAME, path,"/"); pid=path[3]
            if($1=="Uid:") users[pid]=$2
            if($1=="VmRSS:") rss[pid]=$2*1024
        }
        END {for(pid in names) {
            if(++count>2000) continue
            printf "process\t%s\t%s\t%s\t%.6f\t%.2f\t%s\t%s\n",pid,users[pid],((pid in rss)?sprintf("%.0f",rss[pid]):""),cpu[pid],elapsed[pid],names[pid],started[pid]
        } if(count>2000) print "warning\tprocess-truncated" }
        ' /proc/[0-9]*/stat /proc/[0-9]*/status 2>/dev/null
    else
        warning process-limited
        ps -A -o pid=,user=,rss=,time=,etime=,comm= 2>/dev/null | awk '
        function duration(value, parts,count,total,day) {day=0; if(index(value,"-")){split(value,parts,"-");day=parts[1];value=parts[2]} count=split(value,parts,":");total=0;for(i=1;i<=count;i++)total=total*60+parts[i];return total+day*86400}
        NF>=6 && NR<=2000 {name=$6;for(j=7;j<=NF;j++) name=name " " $j; printf "process\t%s\t%s\t%.0f\t%.4f\t%.2f\t%s\t\n",$1,$2,$3*1024,duration($4),duration($5),name}'
    fi
    if [ -r /proc/net/dev ]; then
        awk -F: 'NR>2 && NF==2 {name=$1; gsub(/ /,"",name); split($2,data," "); printf "network\t%s\t%s\t%s\n",name,data[1],data[9]}' /proc/net/dev 2>/dev/null
    else warning network-unavailable; fi
    if command -v ss >/dev/null 2>&1; then
        ports=$(ss -H -lntup 2>/dev/null)
        if [ $? -eq 0 ]; then
            printf '%s\n' "$ports" | awk 'NF>=6 && NR<=4000 {pid="";if(match($0,/pid=[0-9]+/))pid=substr($0,RSTART+4,RLENGTH-4); printf "port\t%s\t%s\t%s\t%s\t%s\n",$1,$5,$6,$2,pid} END {if(NR>4000) print "warning\tports-truncated"}'
        else warning ports-unavailable; fi
    elif [ -r /proc/net/tcp ] && [ -r /proc/net/udp ]; then
        awk 'FNR>1 && ++count<=4000 {protocol=(FILENAME~/udp/?"UDP":"TCP");if(protocol=="UDP" || $4=="0A") printf "portHex\t%s\t%s\t%s\t%s\t\n",protocol,$2,$3,(protocol=="TCP"?"LISTEN":"BOUND")} END {if(count>4000) print "warning\tports-truncated"}' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
    else warning ports-unavailable; fi
    ;;
Darwin)
    if [ "$1" = info ]; then
        info os "$(sw_vers -productName) $(sw_vers -productVersion)"
        info model "$(sysctl -n hw.model 2>/dev/null)"
        info cpuModel "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
        info logicalCPUs "$(sysctl -n hw.logicalcpu 2>/dev/null)"
        info physicalCPUs "$(sysctl -n hw.physicalcpu 2>/dev/null)"
        warning process-scope
        warning process-bandwidth-unavailable
    fi
    boot=$(sysctl -n kern.boottime 2>/dev/null | awk '{gsub(/,/,"",$4); print $4}')
    now=$(date +%s)
    if [ -n "$boot" ]; then printf 'uptime\t%s\n' "$((now-boot))"; fi
    total=$(sysctl -n hw.memsize 2>/dev/null)
    vm_stat 2>/dev/null | awk -v total="$total" '
    NR==1 {for(i=1;i<=NF;i++)if($i=="of")page=$(i+1)}
    /^Pages free:/ {free=$3+0} /^Pages inactive:/ {inactive=$3+0} /^Pages speculative:/ {speculative=$3+0}
    END {if(total>0 && page>0)printf "memory\t%.0f\t%.0f\n",total,total-(free+inactive+speculative)*page; else print "warning\tmemory-unavailable"}'
    top -l 2 -s 1 -n 0 2>/dev/null | awk '/CPU usage:/ {idle=$7+0; found=1} END {if(found)printf "cpuPercent\t%.2f\n",100-idle; else print "warning\tcpu-unavailable"}'
    ps -A -o pid=,user=,rss=,time=,etime=,lstart=,comm= 2>/dev/null | awk '
    function duration(value, parts,count,total,day) {day=0;if(index(value,"-")){split(value,parts,"-");day=parts[1];value=parts[2]}count=split(value,parts,":");total=0;for(i=1;i<=count;i++)total=total*60+parts[i];return total+day*86400}
    NF>=11 && NR<=2000 {name=$11;for(j=12;j<=NF;j++)name=name " " $j;gsub(/[\t\r]/," ",name);printf "process\t%s\t%s\t%.0f\t%.4f\t%.2f\t%s\t%s %s %s %s %s\n",$1,$2,$3*1024,duration($4),duration($5),name,$6,$7,$8,$9,$10}
    END {if(NR>2000)print "warning\tprocess-truncated"}'
    netstat -ibn 2>/dev/null | awk '
    NR==1 {for(i=1;i<=NF;i++){if($i=="Ibytes")rx=i;if($i=="Obytes")tx=i}}
    $3 ~ /^<Link#/ && rx && tx && !seen[$1]++ {shift=(NF==10?1:0); if($(rx-shift)~/^[0-9]+$/ && $(tx-shift)~/^[0-9]+$/)printf "network\t%s\t%s\t%s\n",$1,$(rx-shift),$(tx-shift)}'
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP -sTCP:LISTEN -iUDP -FpcnPt 2>/dev/null | awk '
        /^p/ {pid=substr($0,2)} /^P/ {protocol=substr($0,2)}
        /^n/ && ++count<=4000 {local=substr($0,2);state=(protocol=="TCP"?"LISTEN":"BOUND");sub(/ \(.*\)$/, "",local);gsub(/[\t\r]/," ",local);printf "port\t%s\t%s\t*\t%s\t%s\n",protocol,local,state,pid}
        END {if(count>4000)print "warning\tports-truncated"}'
    else warning ports-unavailable; fi
    ;;
*) warning unsupported-system ;;
esac
df -Pk 2>/dev/null | awk 'NR>1 && $2~/^[0-9]+$/ && $2>0 {mount=$6;for(i=7;i<=NF;i++)mount=mount " " $i;gsub(/[\t\r]/," ",mount);printf "disk\t%s\t%.0f\t%.0f\t%.0f\n",mount,$2*1024,$3*1024,$4*1024}'
warning port-owner-permissions
warning process-scope
warning process-bandwidth-unavailable
