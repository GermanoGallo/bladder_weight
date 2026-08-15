// =====================================================================
//  Detrusor_Teste.ijm  -  versao minima, so para testar o algoritmo
//
//  Nao grava nada: nem CSV, nem .roi, nem ROI Manager. Nao precisa ser
//  instalada. Apenas traca as duas bordas e mostra as metricas.
//
//  COMO USAR (ImageJ.JS com ?run=)
//    Publique este arquivo num Gist (https://gist.github.com) e abra:
//      https://ij.imjoy.io/?run=<url_do_gist>
//    A macro entra em espera assim que o app carrega. Abra a imagem
//    normalmente (File > Open ou arrastando para a janela); a macro
//    detecta a imagem sozinha e ativa a ferramenta de PONTO.
//
//  COMO USAR (rodando na mao)
//    Plugins > New > Macro, colar, Ctrl+R. Funciona igual.
//
//  ACIONAMENTO (nao depende de eventos de mouse: a macro vigia a SELECAO)
//    marcar um PONTO dentro da faixa hipoecoica -> traca as bordas ali
//    arrastar um no do poligono                 -> metricas recalculadas
//                                                  automaticamente
//    tracar uma LINHA (ferramenta linha)        -> encerra a macro
//
//  Saida: poligono na imagem + metricas na barra de status e na janela Log.
//
//  CRITERIOS DE ANALISE (recalibrados em 15/08/2026 com 10 medidas
//  corrigidas manualmente e 9 pares de ROI auto/final)
//    - Dperp e a medida primaria de espessura. Fmin superestima em 1.50x
//      +- 0.10 e passou a ser indicador de forma, nao de espessura.
//    - Janela de busca reduzida de 1.20 para 0.70 mm: a distancia do
//      clique ate a borda corrigida nunca passou de 0.503 mm.
//    - Alerta de saturacao (borda encostada no limite da janela): detectou
//      o unico erro grosseiro da serie sem nenhum falso positivo.
//    - RAF passou de 3.0 para 6.0: com 3.0 o alerta nunca disparava.
//    - Espessura fora de 0.25 a 0.95 mm sinaliza revisao.
//    - lambda e blur mantidos: as bordas automaticas ja saem mais suaves
//      que as corrigidas a mao.
//    - A linha-base da busca acompanha a inclinacao local (estimada em uma
//      passada piloto no trecho central). Com linha-base horizontal, um
//      detrusor obliquo escapa da janela e o poligono corta a parede em
//      diagonal, inflando o Dperp.
// =====================================================================

// ------------------------------------------------------------- parametros
//  Valores recalibrados a partir de 10 medidas corrigidas manualmente
//  (IM_0002/0003/0006/0007, sagital, pre-miccional, 30 MHz, ~0.025 mm/px).
//  Ver o bloco CRITERIOS DE ANALISE no fim deste cabeçalho de secao.

var halfWidthMm         = 4.0;    // meia-largura da janela, imagem calibrada
// 1.20 antes. Nas 10 medidas corrigidas a distancia do clique ate a borda
// nunca passou de 0.503 mm (p90 = 0.497). Com 1.20 a janela permitia uma
// "espessura" de ate 2.4 mm, tres vezes o maximo real, e foi exatamente o
// que produziu o unico erro grosseiro da serie (caso 6: 1.545 mm no
// automatico contra 0.514 mm apos correcao). 0.70 mantem ~40% de folga.
var maxHalfThicknessMm  = 0.70;   // espessura maxima buscada, calibrada
var halfWidthPx         = 160;    // meia-largura, imagem SEM calibracao
var maxHalfThicknessPx  = 28;     // espessura maxima, imagem SEM calibracao
var minHalfThicknessPx  = 2;
// Mantidos: as bordas automaticas ja saem MAIS suaves que as corrigidas a
// mao (rugosidade media 0.044 mm contra 0.083 mm). Aumentar lambda so
// brigaria com o operador; o problema nunca foi falta de suavidade.
var lambda              = 0.60;   // suavidade do caminho
var blurSigma           = 1.00;   // blur anti-speckle, em pixels
var nodesPerBorder      = 12;     // nos por borda
// 3.0 antes, e nunca disparou: o menor RAF automatico da serie foi 4.20,
// justamente o caso que falhou. O segundo menor foi 7.13, numa medida boa.
var rafThreshold        = 6.0;    // limiar de RAF para sinalizar revisao
// Faixa plausivel da espessura do detrusor nesta serie (Dperp corrigido
// variou de 0.313 a 0.797 mm). Fora disso, revisar.
var espMinMm            = 0.25;
var espMaxMm            = 0.95;
// Fracao das colunas que pode encostar no limite da janela antes de o
// tracado ser considerado saturado (indicador causal de fuga da borda).
var satTolerancia       = 0.05;
// A linha-base da busca acompanha a inclinacao local do detrusor. Sem isso,
// numa faixa obliqua a janela de +-0.70 mm e vencida pela deriva: a 20 graus
// o detrusor desce ~1.5 mm ao longo dos 4 mm de janela.
var seguirInclinacao    = true;
var inclinacaoMax       = 0.70;   // dy/dx maximo aceito (~35 graus)
var inclinacaoMin       = 0.05;   // abaixo disso trata como horizontal
var fracaoPiloto        = 0.35;   // trecho central usado para medir a inclinacao

// ------------------------------------------------------------ estado interno
var calX = 1.0;
var calY = 1.0;
var uncalibrated = false;
var lastUpperCount = -1;
// Fracao das colunas em que cada borda automatica encostou no limite da
// janela de busca. Preenchido por trace(), lido por relatorio().
var satSup = 0;
var satInf = 0;
// Inclinacao (dy/dx) estimada para a linha-base e maximo absoluto do
// gradiente da faixa extraida.
var inclinacaoAtual = 0;
var gradMaxAbs = 1;


// ================================================================== inicio
//  Laco residente: sobrevive a ausencia de imagem, porque com ?run= a macro
//  comeca antes de o usuario abrir qualquer arquivo.

var LIMITE_MIN = 120;     // encerra sozinha apos este tempo de sessao (min)
var ultimoX = newArray(0);   // ultimo poligono conhecido, para detectar edicao
var ultimoY = newArray(0);

print("\\Clear");
print("Detrusor (teste) ativo.");
print("  1. Abra a imagem.");
print("  2. Marque um PONTO dentro da faixa hipoecoica (ferramenta ponto).");
print("  3. Arraste os nos do poligono: as metricas se atualizam sozinhas.");
print("  Para encerrar: trace uma LINHA com a ferramenta linha.");
showStatus("Detrusor: aguardando uma imagem...");

fimSessao = getTime() + LIMITE_MIN * 60000;
semImagem = true;
rodando = true;
editando = false;
tEdicao = 0;

while (rodando && getTime() < fimSessao) {
    if (nImages == 0) {
        if (!semImagem) {
            showStatus("Detrusor: aguardando uma imagem...");
            semImagem = true;
        }
        wait(400);
    } else {
        if (semImagem) {
            setTool("point");
            showStatus("Detrusor: marque um ponto na faixa hipoecoica.");
            semImagem = false;
        }

        st = selectionType();

        if (st == 10) {                      // ponto: novo tracado
            Roi.getCoordinates(sx, sy);
            if (lengthOf(sx) > 0) {
                px0 = round(sx[0]);
                py0 = round(sy[0]);
                run("Select None");
                mede(px0, py0);
                editando = false;
            }
            wait(120);

        } else if (st == 5 || st == 6 || st == 7) {   // linha: encerra
            rodando = false;

        } else if (st == 2) {                // poligono: vigia edicao dos nos
            if (poligonoMudou()) {
                relatorio(-1, -1, -1, false);   // atualiza status/overlay
                guardaPoligono();
                editando = true;
                tEdicao = getTime();
            } else if (editando && getTime() - tEdicao > 700) {
                relatorio(-1, -1, -1, true);    // estabilizou: registra no Log
                editando = false;
            }
            wait(120);

        } else {
            wait(200);
        }
    }
}

if (rodando) print("Detrusor: sessao encerrada por tempo (" + LIMITE_MIN + " min).");
else print("Detrusor: encerrado pelo usuario.");
showStatus("Detrusor: encerrado.");


// ============================================================ laco auxiliar

/* Guarda o poligono corrente como referencia. */
function guardaPoligono() {
    Roi.getCoordinates(vx, vy);
    ultimoX = Array.copy(vx);
    ultimoY = Array.copy(vy);
}

/* True se o poligono corrente difere do que foi guardado. */
function poligonoMudou() {
    Roi.getCoordinates(vx, vy);
    n = lengthOf(vx);
    if (n != lengthOf(ultimoX)) return true;
    for (i = 0; i < n; i++) {
        if (abs(vx[i] - ultimoX[i]) > 0.01) return true;
        if (abs(vy[i] - ultimoY[i]) > 0.01) return true;
    }
    return false;
}

/* Traca e mede a partir de um ponto. */
function mede(xc, yc) {
    t0 = getTime();
    cal = pixelSizeMm();
    uncalibrated = (lengthOf(cal) < 2);
    if (uncalibrated) cal = newArray(1.0, 1.0);
    calX = cal[0];
    calY = cal[1];

    if (!trace(xc, yc)) {
        showStatus("Detrusor: nao foi possivel tracar as bordas aqui.");
        print("Detrusor: falha no tracado em (" + xc + ", " + yc + ").");
        print("  Janela pequena demais ou ponto perto demais da borda da imagem.");
        ultimoX = newArray(0);
        ultimoY = newArray(0);
    } else {
        relatorio(xc, yc, getTime() - t0, true);
        guardaPoligono();
    }
}


// ================================================================= relatorio

function relatorio(xc, yc, dt, imprime) {
    Roi.getCoordinates(fx, fy);
    n = lengthOf(fx);

    fer  = feretMinMax(fx, fy, n);
    fmin = fer[0];
    fmax = fer[1];
    raf  = NaN;
    if (fmin > 0) raf = fmax / fmin;

    dperp = NaN;
    if (lastUpperCount > 0 && n == lastUpperCount * 2)
        dperp = meanPerpendicular(fx, fy, n, lastUpperCount);

    u = "mm";
    if (uncalibrated) u = "px";

    // ------------------------------------------------------ criterios de QC
    //  Dperp e a medida primaria. Fmin (menor Feret do envoltorio convexo)
    //  superestima a espessura de forma sistematica nesta geometria: nas 10
    //  medidas corrigidas a razao Fmin/Dperp ficou em 1.50 +- 0.10
    //  (faixa 1.30 a 1.66), porque a faixa e alongada e levemente curva.
    //  Fmin fica como indicador secundario de forma, nao de espessura.
    alerta = "";
    if (satSup > satTolerancia || satInf > satTolerancia)
        alerta = alerta + "  << BORDA NO LIMITE DA JANELA";
    if (raf < rafThreshold)
        alerta = alerta + "  << RAF BAIXO";
    if (!uncalibrated && !isNaN(dperp) && (dperp < espMinMm || dperp > espMaxMm))
        alerta = alerta + "  << ESPESSURA ATIPICA";

    s = "Esp " + d2s(dperp, 3) + " " + u;
    if (isNaN(dperp)) s = "Esp indisponivel";
    if (uncalibrated) s = s + "  (SEM CALIBRACAO)";
    s = s + "  |  Fmin " + d2s(fmin, 3);
    s = s + "  |  RAF " + d2s(raf, 1);
    s = s + alerta;
    showStatus(s);

    Overlay.remove;
    setFont("SansSerif", 13);
    if (lengthOf(alerta) > 0) setColor("orange"); else setColor("yellow");
    Roi.getBounds(bx, by, bw, bh);
    Overlay.drawString(s, bx, maxOf(14, by - 8));
    Overlay.show;

    if (imprime) {
        print("--- Detrusor (teste) -------------------------------");
        if (xc >= 0) print("  ponto           : (" + xc + ", " + yc + ")");
        else         print("  (apos ajuste manual dos nos)");
        if (uncalibrated)
            print("  calibracao      : NENHUMA (medidas em pixels)");
        else
            print("  calibracao      : " + d2s(calX, 5) + " x " + d2s(calY, 5) + " mm/px");
        print("  Dperp (primaria): " + d2s(dperp, 4) + " " + u);
        print("  Fmin (secundar.): " + d2s(fmin, 4) + " " + u
              + "   [esperado ~1.5x Dperp]");
        print("  Fmax            : " + d2s(fmax, 4) + " " + u);
        print("  RAF (Fmax/Fmin) : " + d2s(raf, 2));
        print("  saturacao       : sup " + d2s(satSup * 100, 0)
              + "%  inf " + d2s(satInf * 100, 0) + "% das colunas");
        print("  inclinacao      : " + d2s(inclinacaoAtual, 3) + " dy/dx  ("
              + d2s(atan(inclinacaoAtual) * 180 / PI, 1) + " graus)");
        if (lengthOf(alerta) > 0) print("  QC              : REVISAR ->" + alerta);
        else                      print("  QC              : ok");
        print("  vertices        : " + n + " (" + lastUpperCount + " por borda)");
        if (dt >= 0) print("  tempo           : " + dt + " ms");
    }
}


// =================================================================== tracado
//  A busca segue uma linha-base INCLINADA, nao a horizontal. Sem isso, num
//  detrusor obliquo a faixa sai da janela ao longo dos 4 mm e o poligono
//  atravessa a parede em vez de acompanha-la (Dperp inflado, RAF baixo).
//
//  Duas passadas:
//    1. janela horizontal estreita, linha-base horizontal, so para estimar
//       a inclinacao local pela linha media entre as duas bordas;
//    2. janela completa, linha-base inclinada por essa estimativa.
//  O gradiente e extraido uma unica vez, numa faixa alta o bastante para
//  comportar a deriva maxima admitida.

function trace(xc, yc) {
    w = getWidth();
    h = getHeight();

    if (uncalibrated) {
        halfW   = round(halfWidthPx);
        maxHalf = round(maxHalfThicknessPx);
    } else {
        halfW   = round(halfWidthMm / calX);
        maxHalf = round(maxHalfThicknessMm / calY);
    }
    if (halfW < 5) halfW = 5;
    if (maxHalf < minHalfThicknessPx + 2) maxHalf = minHalfThicknessPx + 2;

    x0 = maxOf(1, xc - halfW);
    x1 = minOf(w - 2, xc + halfW);
    if (x1 - x0 < 8) return false;
    nx = x1 - x0 + 1;

    // Faixa vertical a extrair: espessura buscada + deriva maxima da
    // linha-base inclinada nas extremidades da janela.
    deriva  = round(inclinacaoMax * maxOf(xc - x0, x1 - xc));
    bandTop = maxOf(1,     yc - maxHalf - deriva);
    bandBot = minOf(h - 2, yc + maxHalf + deriva);
    nb = bandBot - bandTop + 1;
    if (nb < 2 * minHalfThicknessPx + 4) return false;

    grad = gradienteVertical(x0, nx, bandTop, nb, h);
    if (lengthOf(grad) == 0) return false;
    maxAbs = gradMaxAbs;

    ny = maxHalf - minHalfThicknessPx + 1;
    if (ny < 2) return false;

    // ---- passada 1: inclinacao a partir de um trecho central curto ------
    inclin = 0;
    if (seguirInclinacao) {
        meia = round(nx * fracaoPiloto / 2);
        if (meia < 6) meia = 6;
        ia = maxOf(0, round((xc - x0)) - meia);
        ib = minOf(nx - 1, round((xc - x0)) + meia);
        if (ib - ia >= 8) {
            t1s = baseLinha(x0, nx, xc, yc, 0, -1, maxHalf, minHalfThicknessPx, bandTop, bandBot);
            t1i = baseLinha(x0, nx, xc, yc, 0,  1, minHalfThicknessPx, maxHalf, bandTop, bandBot);
            p1s = caminho(grad, nx, bandTop, t1s, ia, ib, ny, maxAbs, true);
            p1i = caminho(grad, nx, bandTop, t1i, ia, ib, ny, maxAbs, false);
            if (lengthOf(p1s) > 0 && lengthOf(p1i) > 0) {
                nc = ib - ia + 1;
                mid = newArray(nc);
                for (i = 0; i < nc; i++) mid[i] = (p1s[i] + p1i[i]) / 2;
                inclin = ajusteReta(mid);
                if (inclin >  inclinacaoMax) inclin =  inclinacaoMax;
                if (inclin < -inclinacaoMax) inclin = -inclinacaoMax;
                if (abs(inclin) < inclinacaoMin) inclin = 0;
            }
        }
    }
    inclinacaoAtual = inclin;

    // ---- passada 2: janela completa sobre a linha-base inclinada --------
    topsSup = baseLinha(x0, nx, xc, yc, inclin, -1, maxHalf, minHalfThicknessPx, bandTop, bandBot);
    topsInf = baseLinha(x0, nx, xc, yc, inclin,  1, minHalfThicknessPx, maxHalf, bandTop, bandBot);

    upper = caminho(grad, nx, bandTop, topsSup, 0, nx - 1, ny, maxAbs, true);
    lower = caminho(grad, nx, bandTop, topsInf, 0, nx - 1, ny, maxAbs, false);
    if (lengthOf(upper) == 0 || lengthOf(lower) == 0) return false;

    for (i = 0; i < nx; i++)
        if (lower[i] <= upper[i]) lower[i] = upper[i] + 1;

    // Saturacao medida contra os limites de CADA coluna, ja inclinados.
    nSup = 0;
    nInf = 0;
    for (i = 0; i < nx; i++) {
        if (upper[i] <= topsSup[i])          nSup++;
        if (lower[i] >= topsInf[i] + ny - 1) nInf++;
    }
    satSup = nSup / nx;
    satInf = nInf / nx;

    up = resamplePath(x0, upper, nodesPerBorder);
    lo = resamplePath(x0, lower, nodesPerBorder);

    n  = nodesPerBorder * 2;
    px = newArray(n);
    py = newArray(n);
    for (i = 0; i < nodesPerBorder; i++) {
        px[i] = up[i];
        py[i] = up[nodesPerBorder + i];
    }
    for (i = 0; i < nodesPerBorder; i++) {
        k = nodesPerBorder - 1 - i;
        px[nodesPerBorder + i] = lo[k];
        py[nodesPerBorder + i] = lo[nodesPerBorder + k];
    }

    lastUpperCount = nodesPerBorder;
    makeSelection("polygon", px, py);
    return true;
}

/* Limite superior da faixa de busca em cada coluna, seguindo a linha-base
   inclinada. lado = -1 para a borda de cima, +1 para a de baixo.
   dIni/dFim sao as distancias, em pixels, da linha-base ate o inicio e o
   fim da faixa daquele lado. Retorna o y absoluto da linha j = 0. */
function baseLinha(x0, nx, xc, yc, inclin, lado, dIni, dFim, bandTop, bandBot) {
    tops = newArray(nx);
    ny = dFim - dIni + 1;
    for (i = 0; i < nx; i++) {
        c = yc + inclin * (x0 + i - xc);
        if (lado < 0) t = round(c) - dFim;      // de -dFim ate -dIni
        else          t = round(c) + dIni;      // de +dIni ate +dFim
        if (t < bandTop) t = bandTop;
        if (t + ny - 1 > bandBot) t = bandBot - ny + 1;
        tops[i] = t;
    }
    return tops;
}

/* Inclinacao (dy/dx) por minimos quadrados sobre a linha media. */
function ajusteReta(y) {
    n = lengthOf(y);
    if (n < 3) return 0;
    sx = 0; sy = 0; sxx = 0; sxy = 0;
    for (i = 0; i < n; i++) {
        sx  = sx + i;
        sy  = sy + y[i];
        sxx = sxx + i * i;
        sxy = sxy + i * y[i];
    }
    den = n * sxx - sx * sx;
    if (abs(den) < 1e-9) return 0;
    return (n * sxy - sx * sy) / den;
}

/* Extrai o gradiente vertical da faixa e guarda o maximo absoluto em
   gradMaxAbs. Uma copia 32-bit, blur anti-speckle e convolucao
   0 -1 0 / 0 0 0 / 0 1 0, que equivale a f(x,y+1) - f(x,y-1). */
function gradienteVertical(x0, nx, bandTop, nb, h) {
    origID = getImageID();
    setBatchMode(true);
    run("Select None");
    run("Duplicate...", "title=DETRUSOR_TMP");
    tmpID = getImageID();
    run("32-bit");
    if (blurSigma > 0) run("Gaussian Blur...", "sigma=" + blurSigma);
    run("Convolve...", "text1=[0 -1 0\n0 0 0\n0 1 0\n]");

    makeRectangle(x0, 1, nx, h - 2);
    getStatistics(aTmp, mTmp, gMin, gMax);
    gradMaxAbs = maxOf(abs(gMin), abs(gMax));
    if (gradMaxAbs < 0.000001) gradMaxAbs = 0.000001;

    g = newArray(nx * nb);
    for (j = 0; j < nb; j++) {
        makeRectangle(x0, bandTop + j, nx, 1);
        p = getProfile();
        off = j * nx;
        for (i = 0; i < nx; i++) g[off + i] = p[i];
    }
    run("Select None");
    selectImage(tmpID);
    close();
    selectImage(origID);
    setBatchMode(false);
    return g;
}

/* Caminho de custo minimo nas colunas i0..i1, dentro da faixa de ny linhas
   que comeca em tops[i] na coluna i. Retorna as ordenadas absolutas. */
function caminho(grad, nx, bandTop, tops, i0, i1, ny, maxAbs, wantNegative) {
    nc = i1 - i0 + 1;
    if (nc < 2 || ny < 2) return newArray(0);

    sgn = -1;
    if (wantNegative) sgn = 1;

    D = newArray(nc * ny);
    B = newArray(nc * ny);

    base = (tops[i0] - bandTop) * nx + i0;
    for (j = 0; j < ny; j++) {
        D[j] = sgn * grad[base + j * nx] / maxAbs;
        B[j] = j;
    }

    for (i = 1; i < nc; i++) {
        col  = i0 + i;
        cur  = i * ny;
        prev = (i - 1) * ny;
        // Deslocamento da faixa entre colunas vizinhas: o indice j segue a
        // linha-base, entao a penalidade lambda pune o desvio EM RELACAO a
        // inclinacao, e nao o simples fato de descer.
        desl = tops[col] - tops[col - 1];
        gbase = (tops[col] - bandTop) * nx + col;
        for (j = 0; j < ny; j++) {
            best  = 999999;
            bestK = j;
            for (dj = -1; dj <= 1; dj++) {
                k = j + dj + desl;
                if (k >= 0 && k < ny) {
                    v = D[prev + k] + lambda * abs(dj);
                    if (v < best) { best = v; bestK = k; }
                }
            }
            if (best > 999998) {
                k = j + desl;
                if (k < 0) k = 0;
                if (k > ny - 1) k = ny - 1;
                best = D[prev + k] + lambda;
                bestK = k;
            }
            D[cur + j] = best + sgn * grad[gbase + j * nx] / maxAbs;
            B[cur + j] = bestK;
        }
    }

    last = (nc - 1) * ny;
    j = 0;
    for (k = 1; k < ny; k++)
        if (D[last + k] < D[last + j]) j = k;

    path = newArray(nc);
    for (i = nc - 1; i >= 0; i--) {
        path[i] = tops[i0 + i] + j;
        j = B[i * ny + j];
    }
    return path;
}

/* Reamostra o caminho em n nos. Retorna 2n valores: [x..., y...]. */
function resamplePath(x0, path, n) {
    nx  = lengthOf(path);
    out = newArray(2 * n);
    for (i = 0; i < n; i++) {
        t = 0;
        if (n > 1) t = i * (nx - 1) / (n - 1);
        i0 = floor(t);
        i1 = minOf(nx - 1, i0 + 1);
        f  = t - i0;
        out[i]     = x0 + t;
        out[n + i] = path[i0] * (1 - f) + path[i1] * f;
    }
    return out;
}

// ================================================================== metricas

function feretMinMax(fx, fy, n) {
    cx = newArray(n);
    cy = newArray(n);
    for (i = 0; i < n; i++) {
        cx[i] = fx[i] * calX;
        cy[i] = fy[i] * calY;
    }
    hull = convexHull(cx, cy, n);
    m = lengthOf(hull) / 2;
    if (m < 2) return newArray(0, 0);

    fmax = 0;
    for (i = 0; i < m; i++) {
        for (j = i + 1; j < m; j++) {
            dx = hull[i] - hull[j];
            dy = hull[m + i] - hull[m + j];
            d  = sqrt(dx * dx + dy * dy);
            if (d > fmax) fmax = d;
        }
    }

    fmin = 1e30;
    for (i = 0; i < m; i++) {
        ax = hull[i];
        ay = hull[m + i];
        i2 = (i + 1) % m;
        ex = hull[i2] - ax;
        ey = hull[m + i2] - ay;
        len = sqrt(ex * ex + ey * ey);
        if (len >= 1e-12) {
            maxDist = 0;
            for (k = 0; k < m; k++) {
                d = abs((hull[k] - ax) * ey - (hull[m + k] - ay) * ex) / len;
                if (d > maxDist) maxDist = d;
            }
            if (maxDist < fmin) fmin = maxDist;
        }
    }
    if (fmin > 1e29) fmin = 0;
    return newArray(fmin, fmax);
}

/* Envoltorio convexo (monotone chain). Retorna 2m valores: [x..., y...].
   Atencao: a linguagem de macro NAO faz curto-circuito em &&, por isso os
   testes de indice ficam fora das condicoes compostas. */
function convexHull(px, py, n) {
    if (n < 3) {
        r = newArray(2 * n);
        for (i = 0; i < n; i++) { r[i] = px[i]; r[n + i] = py[i]; }
        return r;
    }
    sx = Array.copy(px);
    sy = Array.copy(py);
    for (i = 1; i < n; i++) {
        kx = sx[i];
        ky = sy[i];
        j = i - 1;
        while (j >= 0) {
            maior = false;
            if (sx[j] > kx) maior = true;
            else if (sx[j] == kx && sy[j] > ky) maior = true;
            if (!maior) break;
            sx[j + 1] = sx[j];
            sy[j + 1] = sy[j];
            j--;
        }
        sx[j + 1] = kx;
        sy[j + 1] = ky;
    }

    hx = newArray(2 * n);
    hy = newArray(2 * n);
    k = 0;
    for (i = 0; i < n; i++) {
        while (k >= 2) {
            if (cross(hx[k-2], hy[k-2], hx[k-1], hy[k-1], sx[i], sy[i]) > 0) break;
            k--;
        }
        hx[k] = sx[i];
        hy[k] = sy[i];
        k++;
    }
    lower = k + 1;
    for (i = n - 2; i >= 0; i--) {
        while (k >= lower) {
            if (cross(hx[k-2], hy[k-2], hx[k-1], hy[k-1], sx[i], sy[i]) > 0) break;
            k--;
        }
        hx[k] = sx[i];
        hy[k] = sy[i];
        k++;
    }

    m = maxOf(k - 1, 1);
    r = newArray(2 * m);
    for (i = 0; i < m; i++) { r[i] = hx[i]; r[m + i] = hy[i]; }
    return r;
}

function cross(ox, oy, ax, ay, bx, by) {
    return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);
}

function meanPerpendicular(fx, fy, n, nUpper) {
    nlo = n - nUpper;
    if (nlo < 2) return NaN;
    lox = newArray(nlo);
    loy = newArray(nlo);
    idx = 0;
    for (i = n - 1; i >= nUpper; i--) {
        lox[idx] = fx[i] * calX;
        loy[idx] = fy[i] * calY;
        idx++;
    }
    sum = 0;
    count = 0;
    for (i = 0; i < nUpper; i++) {
        qx = fx[i] * calX;
        qy = fy[i] * calY;
        best = 1e30;
        for (j = 0; j < nlo - 1; j++) {
            d = pointToSegment(qx, qy, lox[j], loy[j], lox[j+1], loy[j+1]);
            if (d < best) best = d;
        }
        if (best < 1e29) { sum = sum + best; count++; }
    }
    if (count > 0) return sum / count;
    return NaN;
}

function pointToSegment(pxx, pyy, ax, ay, bx, by) {
    vx = bx - ax;
    vy = by - ay;
    wx = pxx - ax;
    wy = pyy - ay;
    vv = vx * vx + vy * vy;
    t = 0;
    if (vv >= 1e-12) t = (wx * vx + wy * vy) / vv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    dx = pxx - (ax + t * vx);
    dy = pyy - (ay + t * vy);
    return sqrt(dx * dx + dy * dy);
}


// ================================================================ calibracao

function pixelSizeMm() {
    dx = dicomNumber("0018,602C");
    dy = dicomNumber("0018,602E");
    if (!isNaN(dx) && !isNaN(dy) && dx > 0 && dy > 0)
        return newArray(abs(dx) * 10.0, abs(dy) * 10.0);

    ps = dicomString("0028,0030");
    if (lengthOf(ps) > 0) {
        parts = split(ps, "\\");
        if (lengthOf(parts) == 2) {
            rowSp = parseFloat(parts[0]);
            colSp = parseFloat(parts[1]);
            if (!isNaN(rowSp) && !isNaN(colSp) && rowSp > 0 && colSp > 0)
                return newArray(colSp, rowSp);
        }
    }

    getPixelSize(unit, pw, ph);
    u = toLowerCase(unit);
    f = 0;
    if (startsWith(u, "mm")) f = 1.0;
    else if (startsWith(u, "cm")) f = 10.0;
    else if (startsWith(u, "um") || startsWith(u, "micron")
             || startsWith(u, fromCharCode(181))) f = 0.001;
    else return newArray(0);
    return newArray(pw * f, ph * f);
}

function dicomString(tag) {
    v = getInfo(tag);
    if (lengthOf(v) == 0) return "";
    return replace(v, "^[ \t]+|[ \t]+$", "");
}

function dicomNumber(tag) {
    s = dicomString(tag);
    if (lengthOf(s) == 0) return NaN;
    return parseFloat(s);
}
