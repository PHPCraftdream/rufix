package compiledregexp

import (
	"bytes"
	"fmt"
	"io"
	"regexp/syntax"
)

var programs map[string]*Regexp

func Lookup(pattern string) (*Regexp, bool) {
	re, ok := programs[pattern]
	return re, ok
}

// WriteProgram записывает готовое состояние, включая one-pass и метаданные поиска.
func WriteProgram(w io.Writer, re *Regexp) error {
	var b bytes.Buffer
	fmt.Fprintf(&b, "&Regexp{expr:%q,prog:&syntax.Prog{Start:%d,NumCap:%d,Inst:[]syntax.Inst{", re.expr, re.prog.Start, re.prog.NumCap)
	for _, inst := range re.prog.Inst {
		writeInst(&b, inst)
		b.WriteByte(',')
	}
	b.WriteString("}},")
	if re.onepass != nil {
		fmt.Fprintf(&b, "onepass:&onePassProg{Start:%d,NumCap:%d,Inst:[]onePassInst{", re.onepass.Start, re.onepass.NumCap)
		for _, inst := range re.onepass.Inst {
			b.WriteString("{Inst:")
			writeInst(&b, inst.Inst)
			fmt.Fprintf(&b, ",Next:%#v},", inst.Next)
		}
		b.WriteString("}},")
	}
	fmt.Fprintf(&b, "numSubexp:%d,maxBitStateLen:%d,subexpNames:%#v,prefix:%q,prefixBytes:%#v,prefixRune:%d,prefixEnd:%d,mpool:%d,matchcap:%d,prefixComplete:%t,cond:syntax.EmptyOp(%d),minInputLen:%d,longest:%t}",
		re.numSubexp, re.maxBitStateLen, re.subexpNames, re.prefix, re.prefixBytes, re.prefixRune, re.prefixEnd, re.mpool, re.matchcap, re.prefixComplete, re.cond, re.minInputLen, re.longest)
	_, err := w.Write(b.Bytes())
	return err
}

func writeInst(w io.Writer, inst syntax.Inst) {
	fmt.Fprintf(w, "syntax.Inst{Op:syntax.InstOp(%d),Out:%d,Arg:%d,Rune:%#v}", inst.Op, inst.Out, inst.Arg, inst.Rune)
}
