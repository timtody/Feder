# Key: de-35k-lenkungskreis
Language: de · Characters: 35955 · Speakers: 6
## Must cover
- Lenkungskreis (7. Sitzung) des Projekts NOVA Kredit der Regionalbank Wesertal: Ablösung des Altsystems KREDIS durch ein System von Kaltenbrunn Software
- Ampeln: Scope grün, Qualität gelb, Ressourcen gelb, Termin rot, Budget rot; Gesamtampel auf Wunsch des Sponsors von gelb auf rot gesetzt
- Release 2.3 (Schnittstellenpaket: Kernbank, Meldewesen, Dokumentenarchiv) war für 15. September fällig, kommt nun am 6. November; Ursache: Sicherheiten-Mapping (stand im Lastenheft, Kaltenbrunn übernimmt Verantwortung)
- Gutschrift von Kaltenbrunn über 90.000 € angenommen, aber nicht als Abgeltung von allem: rutscht der 6. November, wird neu verhandelt; Bedingung kommt schriftlich in den Lieferplan
- Jour fixe mit Kaltenbrunn ab sofort wöchentlich (dienstags) statt alle zwei Wochen, mindestens bis Go-live
- Budget: Mehrkosten 750.000 € brutto (nach Korrektur), Forecast 4,95 Mio. € brutto (4,86 Mio. € nach Gutschrift), ca. 17,9 % Überschreitung
- Restliche Projektreserve von 300.000 € vom Sponsor freigegeben; Nachtrag über 360.000 € wird beim Vorstand am 3. November beantragt
- Go-live verschoben: nicht 2. März (ursprünglich) und nicht 12. April 2027 (verworfen wegen IT-Freeze im Q1-Abschluss bis 15. April, Wirtschaftsprüfer im Haus, Frühjahrsgeschäft Baufinanzierung), sondern 10. Mai 2027; Cutover-Wochenende 8./9. Mai
- Urlaubssperre für das Kernteam in den zwei Wochen nach Go-live
- Migrationsgeneralproben bleiben am 13. Februar und 20. März 2027; optional eine dritte Ende April
- Parallelbetrieb von 8 auf 4 Wochen verkürzt (bis 4. Juni 2027), mit definierten Kriterien für eine Verlängerung
- Migrationslead Herr Yilmaz ab 1. November zu 100 % im Projekt (bisher 50 %); Kreditservice erhält für 6 Monate eine halbe Ersatzstelle
- Zwei externe Tester über den Rahmenvertrag mit Feldmann Consulting ab 1. Dezember für 5 Monate (ca. 70.000 €) genehmigt
- Testmeldelauf mit Abgleich gegen das Altsystem in der zweiten Generalprobe (Folge eines Prüfungsbefunds beim Meldewesen)
- Scope Freeze ab heute: keine neuen Change Requests außer regulatorischen Pflichtänderungen; Vertriebswünsche in ein Folgerelease
- Sondersitzung des Lenkungskreises am 11. November; regulärer Termin 9. Dezember bleibt
- Risiko: KREDIS-Lizenz (Datronik) nur bis 30. Juni 2027 verlängerbar, daher ist der 10. Mai faktisch der letzte mögliche Termin; das muss in die Vorstandsvorlage
## Facts (numbers, dates, names)
- Teilnehmer: Katrin Lohmeier (Projektleiterin), Matthias Brenner (Sponsor), Jens Ostrowski (Kaltenbrunn Software, Lieferant), Sabine Krüger (IT-Betrieb), Tobias Wendland (Fachbereich/Kreditservice), Sprecher 6 (Revision)
- SIT: 62 % der Testfälle durchgeführt (geplant 80 %), davon 71 % bestanden
- 214 offene Defects, davon 19 Prio 1; etwa 14 davon hängen an den Schnittstellen
- Genehmigtes Budget 4,2 Mio. €; bis Ende September ausgegeben 2,87 Mio. €
- Mehrkosten-Bausteine: interne Personalkosten ca. 310.000 €, Lizenz und Betrieb KREDIS 140.000 €, Kaltenbrunn-Beratertage Migration 230.000 €, externe Tester 70.000 €
- Projektreserve ursprünglich 420.000 € (10 %), davon 120.000 € im Frühjahr für Bürgschaftsbank-Schnittstellen verbraucht, Rest 300.000 €
- Vertragsstrafe (Pönale) pro Meilenstein vertraglich auf 60.000 € gedeckelt; Gutschrift 90.000 € liegt darüber
- 750.000 − 90.000 = 660.000 € netto; minus 300.000 € Reserve = 360.000 € Nachtrag
- Kernbank-Release 24.2 (August) änderte zwei Felder der Sicherheitenschnittstelle; Kaltenbrunn testete gegen anonymisierte Testdaten vom Juni
- Altbestand ca. 38.000 Kreditverträge; Fehlerquote erste Probemigration 11 %, jetzt 4 % (ca. 1.500 offen); Ziel unter 1 % bis zur ersten Generalprobe
- Pfingsten 2027: 16. Mai
- Frau Pohl (Testkoordinatorin Fachbereich) geht im Januar in Elternzeit; Nachfolger Herr Nowak, Übergabe im Dezember
- Feldmann Consulting braucht ca. 4 Wochen Vorlauf; Berechtigungen für Externe dauern ca. 2 Wochen
- Top-5-Risiken: erneute Verzögerung Release 2.3, Datenmigration, Meldewesen, Abhängigkeit vom Rechenzentrum beim Cutover, KREDIS-Lizenzende
## Tasks
- Jens Ostrowski: schriftlicher, verbindlicher Lieferplan für Release 2.3 mit Testnachweis, inkl. Gutschrift und Bedingung (23. Oktober)
- Sabine Krüger: Delta zur Kernbankversion 24.2 mit Kaltenbrunns technischem Lead klären (diese Woche)
- Sabine Krüger: Cutover-Plan mit dem Rechenzentrum inkl. Change-Fenster abstimmen (13. November)
- Katrin Lohmeier: Vorstandsvorlage für den Nachtrag (28. Oktober)
- Tobias Wendland: fachlichen Teil der Vorstandsvorlage an Katrin liefern (23. Oktober)
- Tobias Wendland: Freistellung von Herrn Yilmaz ab 1. November und halbe Ersatzstelle im Kreditservice (31. Oktober)
- Katrin Lohmeier: Abruf der zwei externen Tester bei Feldmann mit dem Einkauf (4. November); Namen für Berechtigungen an Sabine Krüger (16. November)
- Sprecher 6: Testkonzept für den Testmeldelauf (20. November)
- Sprecher 6 mit Tobias Wendland: Kriterien für Verlängerung des Parallelbetriebs (29. Januar 2027)
- Herr Yilmaz (abwesend, über Katrin): Migrations-Fehlerquote unter 1 % (13. Februar 2027, erste Generalprobe)
- Katrin Lohmeier: Ampeln anpassen (Gesamtstatus rot) und Protokoll verschicken (Freitag)
- Matthias Brenner: Anruf bei der Geschäftsführung von Kaltenbrunn (30. Oktober)
- Katrin Lohmeier: Einladung zur Sondersitzung am 11. November
## Traps
- Go-live 12. April 2027 vorgeschlagen (Cutover 10./11. April) → verworfen; es gilt 10. Mai 2027, Cutover 8./9. Mai
- Mehrkosten 680.000 € (daraus Nachtrag 290.000 €) → korrigiert auf 750.000 € brutto (externe Tester fehlten), Nachtrag 360.000 €
- Vorstandsvorlage zuerst an Tobias Wendland vergeben → neu an Katrin Lohmeier; Tobias liefert nur den fachlichen Teil zu
- Gesamtampel von der Projektleiterin auf gelb gelassen → vom Lenkungskreis auf rot gesetzt
## Misheard words
- Riese (zwei Punkt drei) = Release (2.3)
- Bonale = Pönale
- General Robe = Generalprobe
- Rahmen vertragen = Rahmenvertrag
- Katowa = Cutover
