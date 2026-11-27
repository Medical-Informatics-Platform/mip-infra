{{- /*
remote-networks.overlap: "true" when two IPv4 CIDRs overlap (one contains the
other), else "". Argument: a list of two CIDRs. Both addresses are read as
integers and divided by the block size of the shorter prefix. atoi reads
decimal; Sprig's int would read 010 as octal.
*/ -}}
{{- define "remote-networks.overlap" -}}
{{- $a := splitList "/" (index . 0) -}}
{{- $b := splitList "/" (index . 1) -}}
{{- $block := 1 -}}
{{- range until (int (sub 32 (min (atoi (index $a 1)) (atoi (index $b 1))))) -}}
{{- $block = mul $block 2 -}}
{{- end -}}
{{- $x := 0 -}}
{{- range splitList "." (index $a 0) -}}
{{- $x = add (mul $x 256) (atoi .) -}}
{{- end -}}
{{- $y := 0 -}}
{{- range splitList "." (index $b 0) -}}
{{- $y = add (mul $y 256) (atoi .) -}}
{{- end -}}
{{- if eq (div $x $block) (div $y $block) }}true{{ end -}}
{{- end -}}
