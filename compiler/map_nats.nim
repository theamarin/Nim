#
#
#           The Nim Compiler
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Map Nim expressions to nats.nim's representation.

import std / tables

import ast, types, nats
from trees import getMagic

const
  someLen = {mLengthOpenArray, mLengthStr, mLengthArray, mLengthSeq}
  # we don't list unsigned here because wrap around semantics suck for
  # proving anything:
  someAdd = {mAddI, mAddF64, mSucc}
  someSub = {mSubI, mSubF64, mPred}

type
  Context* = object
    varMap: Table[int, VarId] # Sym Id to VarId
    facts: Facts
    nextVarId: int32

  ContextState* = object
    xlen, ylen, zlen: int

proc recordState*(c: Context): ContextState =
  ContextState(xlen: c.facts.x.len, ylen: c.facts.y.len, zlen: c.facts.z.len)

proc rollback*(c: var Context; s: ContextState) =
  c.facts.x.setLen s.xlen
  c.facts.y.setLen s.ylen
  c.facts.z.setLen s.zlen

proc isLet(n: PNode): bool =
  if n.kind == nkSym:
    if n.sym.kind in {skLet, skTemp, skForVar}:
      result = true
    elif n.sym.kind == skParam and skipTypes(n.sym.typ,
                                             abstractInst).kind notin {tyVar}:
      result = true
  elif n.getMagic in someLen+{mHigh}:
    result = isLet(n[1])

proc isLetOrMin(n: PNode): bool =
  if n.getMagic == mMinI:
    result = isLet(n[1]) and isLet(n[2])
  else:
    result = isLet(n)

proc isLiteral(n: PNode): bool =
  case n.kind
  of nkCharLit..nkInt64Lit:
    result = true
  of nkSym:
    result = n.sym.kind == skConst and isLiteral(n.sym.ast)
  else:
    result = false

proc whichLit(n: PNode): BiggestInt =
  const badValue = -12345678
  case n.kind
  of nkCharLit..nkInt64Lit:
    result = n.intVal
  of nkSym:
    if n.sym.kind == skConst and isLiteral(n.sym.ast):
      result = n.sym.ast.intVal
    else:
      result = badValue # likely to trigger a followup error
  else:
    result = badValue

proc getVarId(c: var Context; n: PNode): VarId =
  let id = if n.kind == nkSym: n.sym.id
           else:
             assert n.getMagic in someLen+{mHigh}
             -n[1].sym.id

  result = c.varMap.getOrDefault(id)
  if result == VarId(0):
    inc c.nextVarId
    result = VarId c.nextVarId
    c.varMap[id] = result

proc isHigh(n: PNode): BiggestInt {.inline.} =
  ord(n.getMagic == mHigh)

proc extractPrimitive(a: PNode): (PNode, BiggestInt) =
  # Extracts (x+3) into 'x' and '3'.
  # (x) is extracted into 'x' and '0'.
  case a.getMagic
  of someAdd:
    if a[1].isLetOrMin and a[2].isLiteral:
      result = (a[1], whichLit(a[2])+isHigh(a[1]))
    elif a[2].isLetOrMin and a[1].isLiteral:
      result = (a[2], whichLit(a[1])+isHigh(a[2]))
    else:
      result = (PNode(nil), BiggestInt(0))
  of someSub:
    if a[1].isLetOrMin and a[2].isLiteral:
      result = (a[1], -whichLit(a[2])+isHigh(a[1]))
    else:
      result = (PNode(nil), BiggestInt(0))
  else:
    if a.isLetOrMin:
      result = (a, isHigh(a))
    else:
      result = (PNode(nil), BiggestInt(0))

proc addCmpFactRaw(c: var Context; facts: var Facts; a, b: PNode; lt: range[-1..0]) =
  if a.isLiteral:
    let (y, yc) = extractPrimitive(b)
    if y != nil:
      if y.getMagic == mMinI:
        # 0 <= min(a, b)
        facts.z.add ValLe(c: yc+whichLit(a)-lt, a: getVarId(c, y[1]))
        facts.z.add ValLe(c: yc+whichLit(a)-lt, a: getVarId(c, y[2]))
      else:
        # semantics: c < a  -->  c+1 <= a
        facts.z.add ValLe(c: yc+whichLit(a)-lt, a: getVarId(c, y))

  else:
    let (x, xc) = extractPrimitive(a)
    if x != nil and x.getMagic != mMinI:
      if b.isLiteral:
        # (x + 3) < c --> x < c - 3
        facts.y.add VarLe(a: getVarId(c, x), c: whichLit(b)+lt-xc)
      else:
        let (y, yc) = extractPrimitive(b)
        if y != nil:
          if y.getMagic == mMinI:
            # x+3 <= min(a, b)
            facts.x.add VarVarLe(a: getVarId(c, x), b: getVarId(c, y[1]), c: yc+lt-xc)
            facts.x.add VarVarLe(a: getVarId(c, x), b: getVarId(c, y[2]), c: yc+lt-xc)
          else:
            facts.x.add VarVarLe(a: getVarId(c, x), b: getVarId(c, y), c: yc+lt-xc)

proc skipStmtListExpr(n: PNode): PNode =
  result = n
  while result.kind in {nkStmtListExpr, nkPar} and result.len > 0:
    result = result.lastSon

proc addFactLe*(c: var Context; a, b: PNode) =
  addCmpFactRaw(c, c.facts, a.skipStmtListExpr, b.skipStmtListExpr, 0)

proc addFactLt*(c: var Context; a, b: PNode) =
  addCmpFactRaw(c, c.facts, a.skipStmtListExpr, b.skipStmtListExpr, -1)

proc addFact*(c: var Context; n: PNode; negation: bool) =
  case n.kind
  of nkStmtListExpr, nkPar:
    addFact(c, n.lastSon, negation)
  of nkCallKinds:
    case n.getMagic
    of mAnd:
      if not negation:
        addFact(c, n[1], negation)
        addFact(c, n[2], negation)
    of mNot:
      addFact(c, n[1], not negation)
    of mOr:
      # 'or' sucks! (p == 3 or q == 4)
      # --> hard to do anything with that knowledge...
      # But the negation of 'or' is useful:
      if negation:
        # not (a or b) <--> (not a) and (not b)
        addFact(c, n[1], true)
        addFact(c, n[2], true)
    of mLeI, mLeF64, mLeU, mLeEnum, mLeCh, mLeB:
      if negation:
        # not (a <= b) <--> b < a
        addFactLt(c, n[2], n[1])
      else:
        addFactLe(c, n[1], n[2])
    of mLtI, mLtF64, mLtU, mLtEnum, mLtCh, mLtB:
      if negation:
        addFactLe(c, n[2], n[1])
      else:
        addFactLt(c, n[1], n[2])
    of mEqI, mEqF64, mEqEnum, mEqCh, mEqB:
      if negation:
        discard "cannot do anything with this 'fact'"
      else:
        # (a == b)  <--> (a <= b) and (b <= a)
        addFactLe(c, n[1], n[2])
        addFactLe(c, n[2], n[1])
    else:
      discard "cannot do anything with this 'fact'"
  else:
    discard "cannot do anything with this 'fact'"

proc addAsgnFact*(c: var Context; a, b: PNode) =
  # (a == b)  <--> (a <= b) and (b <= a)
  addFactLe(c, a, b)
  addFactLe(c, b, a)

proc proveLe*(c: var Context; a, b: PNode): bool =
  var toProve: Facts
  addCmpFactRaw(c, toProve, a.skipStmtListExpr, b.skipStmtListExpr, 0)
  for x in toProve.x:
    if not implies(c.facts, x): return false
  for y in toProve.y:
    if not implies(c.facts, y): return false
  for z in toProve.z:
    if not implies(c.facts, z): return false
  return true