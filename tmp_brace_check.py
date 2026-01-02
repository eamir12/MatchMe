from pathlib import Path
p=Path(r'C:\App\MatchMeGPT5.21\MatchMe3\lib\screens\chats\chat_screen.dart')
s=p.read_text(encoding='utf-8')
stack=[]
line=1; col=1
for i,ch in enumerate(s):
    if ch=='\n':
        line+=1; col=1; continue
    if ch in '({[':
        stack.append((ch,line,col))
    elif ch in ')}]':
        if not stack:
            print('Unmatched closing', ch, 'at', line, col)
            break
        open_ch, ol, oc = stack.pop()
        pairs={')':'(', '}':'{', ']':'['}
        if pairs[ch]!=open_ch:
            print('Mismatch at',line,col,'found',ch,'expected close for',open_ch,'opened at',ol,oc)
            break
    col+=1
else:
    if stack:
        open_ch, ol, oc = stack[-1]
        print('Unclosed opening at', ol, oc, 'char', open_ch)
    else:
        print('All balanced')
print('stack size',len(stack))
if stack:
    print('top of stack sample:', stack[-5:])