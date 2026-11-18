# Refit script for the xG v2 shadow model. Expects data.txt: game,goal,x*10,y*10,mask,xg*1000 per shot, ';' separated (pinned shots only).
# Mask bits: rush1 rebound2 screened4 breakaway8 cross_ice16 deflection32 one_timer64 backhand128 PK256 PP512.
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score, log_loss
from sklearn.model_selection import GroupKFold
rows=[r.split(',') for r in open('data.txt').read().strip().split(';')]
assert all(len(r)==6 for r in rows), [r for r in rows if len(r)!=6][:3]
A=np.array(rows,dtype=float)
game,y,x,yy,mask,xg=A[:,0],A[:,1].astype(int),A[:,2]/10,A[:,3]/10,A[:,4].astype(int),A[:,5]/1000
print(len(y),y.sum())
dist=np.sqrt(x**2+yy**2); ang=np.degrees(np.arctan2(np.abs(x),np.maximum(yy,0.5)))
names=['rush','rebound','screened','breakaway','cross_ice','deflection','one_timer','backhand','PK','PP']
F=np.column_stack([(mask>>i)&1 for i in range(10)])
def feats(cols):
    base=[np.log(dist+1),ang/45]
    return np.column_stack(base+[F[:,names.index(c)] for c in cols])
def cv(X,C=1.0,reps=20):
    ll=[];au=[]; 
    P=np.zeros(len(y))
    rs=np.random.RandomState(0); ug=np.unique(game)
    lls=[];aus=[]
    for r in range(reps):
        perm=rs.permutation(ug); fold={g:i%5 for i,g in enumerate(perm)}
        f=np.array([fold[g] for g in game]); P=np.zeros(len(y))
        for k in range(5):
            tr,te=f!=k,f==k
            m=LogisticRegression(C=C,max_iter=2000).fit(X[tr],y[tr]); P[te]=m.predict_proba(X[te])[:,1]
        lls.append(log_loss(y,P)); aus.append(roc_auc_score(y,P))
    return np.mean(lls),np.mean(aus),P
print('current xG   logloss %.4f  AUC %.3f'%(log_loss(y,xg),roc_auc_score(y,xg)))
print('constant     logloss %.4f'%log_loss(y,np.full(len(y),y.mean())))
for label,cols in [('distance+angle only',[]),('+ rush,rebound,screen,breakaway',['rush','rebound','screened','breakaway']),
  ('+ cross_ice,deflection,one_timer',['rush','rebound','screened','breakaway','cross_ice','deflection','one_timer']),
  ('all 10',names)]:
    l,a,P=cv(feats(cols))
    print('%-36s logloss %.4f  AUC %.3f'%(label,l,a))
X=feats(names); m=LogisticRegression(C=1.0,max_iter=2000).fit(X,y)
print('coefs (odds ratio):')
for n,c in zip(['log_dist','angle']+names,m.coef_[0]): print('  %-10s %.2f  OR %.2f'%(n,c,np.exp(c)))
# calibration of CV preds
l,a,P=cv(feats(names)); q=np.argsort(P); 
for i,idx in enumerate(np.array_split(q,5)): print('quintile',i+1,'pred %.1f%% actual %.1f%% n=%d'%(P[idx].mean()*100,y[idx].mean()*100,len(idx)))
# xg quintile compare
q=np.argsort(xg)
print('xG current: top-quintile actual %.1f%% bottom %.1f%%'%(y[np.array_split(q,5)[4]].mean()*100,y[np.array_split(q,5)[0]].mean()*100))
